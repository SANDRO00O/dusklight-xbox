// HTTP transport for borealis::http on the Xbox (UWP), built on Windows.Web.Http (C++/WinRT).
//
// WHY: the toolchain builds borealis with BOREALIS_HTTP_BACKEND=none, because borealis' Windows backend
// is WinHTTP and WinHTTP is not part of the UWP API set (Microsoft's list of UWP alternatives names
// Windows.Web.Http as its replacement). With backend "none" borealis::http::available() is false, so the
// "Browse online mods" button was disabled and no request was ever sent, whatever capabilities the
// manifest declares (internetClient is still required, see Patch-Manifest.ps1).
//
// HOW: platforms/xbox/xbox-project.cmake swaps borealis' src/http/no_backend.cpp for this file in the
// borealis_http target. borealis::http keeps all request validation, resume logic, file downloads and size
// limits (src/http.cpp, src/http_download.cpp); a backend only has to implement
//   available() / backend() / backend_name() / detail::send_request()
// exactly like src/http/curl.cpp does: send one request, report the response head to the observer, stream
// the body to the observer, and honour cancellation and the deadline.
//
// First console run (build 8415bd1): the backend was selected and compiled, but every request failed with
// 0x80000018 (E_ILLEGAL_DELEGATE_ASSIGNMENT): wait_for() was called in a loop and assigns the Completed
// handler each time. wait_for_operation() below assigns it once.

#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>

#include "borealis/http.hpp"

#include "http_internal.hpp"
#include "borealis/log.hpp"

#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/Windows.Web.Http.h>
#include <winrt/Windows.Web.Http.Filters.h>
#include <winrt/Windows.Web.Http.Headers.h>

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <memory>
#include <span>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace {
constexpr borealis::Log Log{"borealis::http"};

namespace wf = winrt::Windows::Foundation;
namespace wss = winrt::Windows::Storage::Streams;
namespace wh = winrt::Windows::Web::Http;
namespace whf = winrt::Windows::Web::Http::Filters;

std::wstring utf8_to_wide(std::string_view text) {
    if (text.empty()) {
        return {};
    }
    const int size =
        MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0);
    if (size <= 0) {
        return {};
    }
    std::wstring wide(static_cast<size_t>(size), L'\0');
    MultiByteToWideChar(
        CP_UTF8, 0, text.data(), static_cast<int>(text.size()), wide.data(), size);
    return wide;
}

std::string wide_to_utf8(std::wstring_view text) {
    if (text.empty()) {
        return {};
    }
    const int size = WideCharToMultiByte(
        CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
    if (size <= 0) {
        return {};
    }
    std::string utf8(static_cast<size_t>(size), '\0');
    WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), utf8.data(), size,
        nullptr, nullptr);
    return utf8;
}

bool starts_with_content(std::string_view name) {
    constexpr std::string_view Prefix = "content-";
    if (name.size() < Prefix.size()) {
        return false;
    }
    for (size_t i = 0; i < Prefix.size(); ++i) {
        char c = name[i];
        if (c >= 'A' && c <= 'Z') {
            c = static_cast<char>(c - 'A' + 'a');
        }
        if (c != Prefix[i]) {
            return false;
        }
    }
    return true;
}

// Worker threads of borealis' task pool have not initialised WinRT; join the multithreaded apartment.
void ensure_apartment() {
    thread_local bool done = false;
    if (done) {
        return;
    }
    done = true;
    try {
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
    } catch (...) {
        // Already initialised on this thread in another mode; WinRT calls still work.
    }
}

enum class WaitResult {
    Finished,
    Canceled,
    TimedOut,
};

// Waits for an asynchronous operation in short slices so cancellation and the deadline are honoured.
//
// NOT operation.wait_for() in a loop: C++/WinRT's wait_for assigns the operation's Completed handler, and a
// handler may be assigned only once, so the second slice failed with E_ILLEGAL_DELEGATE_ASSIGNMENT
// (0x80000018, "A delegate was assigned when not allowed", seen on the console). The handler is assigned
// once here and signals an event the loop waits on; the event is shared so a late completion after an early
// return (cancel / timeout) never touches a closed handle.
template <typename Async>
WaitResult wait_for_operation(const Async& operation, const borealis::http::detail::TransportRequest& request,
    const borealis::http::detail::Deadline::Tracker& tracker) {
    auto done = std::make_shared<winrt::handle>(
        CreateEventExW(nullptr, nullptr, CREATE_EVENT_MANUAL_RESET, SYNCHRONIZE | EVENT_MODIFY_STATE));
    if (!*done) {
        winrt::throw_last_error();
    }
    operation.Completed([done](const auto&, wf::AsyncStatus) { SetEvent(done->get()); });
    const DWORD pollMs = static_cast<DWORD>(
        std::chrono::duration_cast<std::chrono::milliseconds>(borealis::http::detail::Deadline::PollInterval)
            .count());
    while (true) {
        if (WaitForSingleObjectEx(done->get(), pollMs, FALSE) == WAIT_OBJECT_0) {
            return WaitResult::Finished;
        }
        if (request.signals->cancelRequested.load(std::memory_order_relaxed)) {
            operation.Cancel();
            return WaitResult::Canceled;
        }
        if (request.deadline->expired(tracker)) {
            operation.Cancel();
            return WaitResult::TimedOut;
        }
    }
}

borealis::http::detail::TransportResult stopped(WaitResult result) {
    if (result == WaitResult::Canceled) {
        return {.error = borealis::http::Error::Canceled, .message = "Request canceled"};
    }
    return {.error = borealis::http::Error::Timeout, .message = "Request timed out"};
}

}  // namespace

namespace borealis::http {

bool available() noexcept {
    return true;
}

Backend backend() noexcept {
    // borealis::http::Backend has no entry for Windows.Web.Http; WinHttp is the closest Windows one.
    return Backend::WinHttp;
}

const char* backend_name() noexcept {
    return "Windows.Web.Http";
}

namespace {

detail::TransportResult send_request_impl(const detail::TransportRequest& request) {
    ensure_apartment();

    detail::Deadline::Tracker tracker;

    whf::HttpBaseProtocolFilter filter;
    filter.AllowAutoRedirect(true);
    filter.AutomaticDecompression(request.allowCompression);
    filter.CacheControl().ReadBehavior(whf::HttpCacheReadBehavior::MostRecent);
    filter.CacheControl().WriteBehavior(whf::HttpCacheWriteBehavior::NoCache);
    wh::HttpClient client{filter};

    wh::HttpMethod method = wh::HttpMethod::Get();
    if (request.method == Method::Post) {
        method = wh::HttpMethod::Post();
    } else if (request.method == Method::Head) {
        method = wh::HttpMethod::Head();
    }

    wf::Uri uri{winrt::hstring{utf8_to_wide(request.url)}};
    wh::HttpRequestMessage message{method, uri};

    wh::IHttpContent content{nullptr};
    if (request.method == Method::Post) {
        wss::DataWriter writer;
        if (!request.body.empty()) {
            writer.WriteBytes(winrt::array_view<const uint8_t>(
                reinterpret_cast<const uint8_t*>(request.body.data()),
                static_cast<uint32_t>(request.body.size())));
        }
        content = wh::HttpBufferContent{writer.DetachBuffer()};
        message.Content(content);
    }

    for (const Header& header : request.headers) {
        const winrt::hstring name{utf8_to_wide(header.name)};
        const winrt::hstring value{utf8_to_wide(header.value)};
        bool added = false;
        if (starts_with_content(header.name)) {
            if (content) {
                added = content.Headers().TryAppendWithoutValidation(name, value);
            }
        } else {
            added = message.Headers().TryAppendWithoutValidation(name, value);
        }
        if (!added) {
            ::Log.debug("header '{}' was not accepted by Windows.Web.Http", header.name);
        }
    }

    // Request the head only; the body is streamed below.
    auto sendOperation =
        client.SendRequestAsync(message, wh::HttpCompletionOption::ResponseHeadersRead);
    if (const auto waited = wait_for_operation(sendOperation, request, tracker);
        waited != WaitResult::Finished)
    {
        return stopped(waited);
    }
    wh::HttpResponseMessage response = sendOperation.GetResults();  // throws when the request failed
    tracker.start_response();

    // borealis only accepts https:// URLs; do not follow a redirect that leaves https.
    const auto finalUri = response.RequestMessage().RequestUri();
    if (finalUri && std::wstring_view{finalUri.SchemeName()} != L"https") {
        response.Close();
        return {.error = Error::UnsupportedScheme, .message = "Redirected to a non-HTTPS URL"};
    }

    std::vector<Header> headers;
    const auto collect = [&headers](const auto& collection) {
        for (const auto& pair : collection) {
            headers.push_back(Header{
                .name = wide_to_utf8(pair.Key()),
                .value = wide_to_utf8(pair.Value()),
            });
        }
    };
    collect(response.Headers());
    const auto responseContent = response.Content();
    if (responseContent) {
        collect(responseContent.Headers());
    }

    const int status = static_cast<int>(response.StatusCode());
    if (request.observer->on_response(status, std::move(headers)) ==
        detail::TransportObserver::Directive::Abort)
    {
        response.Close();
        return {.error = Error::Network, .message = "Response rejected"};
    }
    if (!responseContent) {
        return {};
    }

    auto streamOperation = responseContent.ReadAsInputStreamAsync();
    if (const auto waited = wait_for_operation(streamOperation, request, tracker);
        waited != WaitResult::Finished)
    {
        response.Close();
        return stopped(waited);
    }
    const wss::IInputStream stream = streamOperation.GetResults();

    wss::Buffer buffer{64 * 1024};
    std::vector<uint8_t> bytes;
    while (true) {
        auto readOperation =
            stream.ReadAsync(buffer, buffer.Capacity(), wss::InputStreamOptions::Partial);
        if (const auto waited = wait_for_operation(readOperation, request, tracker);
            waited != WaitResult::Finished)
        {
            response.Close();
            return stopped(waited);
        }
        const wss::IBuffer filled = readOperation.GetResults();
        const uint32_t count = filled.Length();
        if (count == 0) {
            break;
        }
        bytes.resize(count);
        wss::DataReader::FromBuffer(filled).ReadBytes(winrt::array_view<uint8_t>(bytes));
        tracker.touch();
        const auto chunk = std::span<const std::byte>{
            reinterpret_cast<const std::byte*>(bytes.data()), bytes.size()};
        if (request.observer->on_data(chunk) == detail::TransportObserver::Directive::Abort) {
            response.Close();
            return {.error = Error::Network, .message = "Response body rejected"};
        }
    }
    response.Close();
    return {};
}

}  // namespace

detail::TransportResult detail::send_request(const TransportRequest& request) {
    try {
        return send_request_impl(request);
    } catch (const winrt::hresult_error& error) {
        const std::string message = wide_to_utf8(error.message());
        ::Log.error("Windows.Web.Http request failed (0x{:08x}): {}",
            static_cast<uint32_t>(static_cast<int32_t>(error.code())), message);
        return {.error = Error::Network, .message = message.empty() ? "HTTP request failed" : message};
    } catch (const std::exception& exception) {
        return {.error = Error::Network, .message = exception.what()};
    } catch (...) {
        return {.error = Error::Network, .message = "HTTP request failed"};
    }
}

}  // namespace borealis::http
