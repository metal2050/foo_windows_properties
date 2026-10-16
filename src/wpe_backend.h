#pragma once
// What the Properties window needs from the outside world. The foobar2000 implementation is in
// wpe_backend_fb2k.cpp; the UI tests use an in-memory one. No SDK, no Cocoa.

#include "wpe_art.h"
#include "wpe_details.h"
#include "wpe_model.h"
#include "wpe_rg.h"

#include <functional>
#include <string>
#include <utility>
#include <vector>

namespace wpe {

struct WriteResult {
    enum Code { Success, Aborted, Errors };
    Code code = Success;
    std::vector<std::pair<std::string, std::string>> errors;  // location, message
};

struct ArtLoad {
    std::vector<art::TrackArt> tracks;                        // indexed like the load order
    std::vector<std::pair<std::string, std::string>> errors;  // location, message (unreadable files)
};

class Backend {
public:
    virtual ~Backend() = default;

    virtual size_t trackCount() const = 0;
    virtual std::string windowTitle() = 0;
    virtual Config config() = 0;

    // Delivers the tracks' fields and ReplayGain values (both in load order) on the main thread.
    // Returns true when `done` already ran synchronously.
    virtual bool load(bool afterWrite, std::function<void(std::vector<TrackFields>, std::vector<rg::Info>)> done) = 0;

    // Writes `plan` (tags and ReplayGain) to the given tracks (indices into the load order). `done`
    // runs on the main thread, possibly before write() returns.
    virtual void write(const Plan& plan, const std::vector<size_t>& tracks, std::function<void(WriteResult)> done) = 0;

    // Called (main thread) when the tracks' tags change outside this window. nullptr stops watching.
    virtual void setChangeHandler(std::function<void()> onChange) = 0;

    // Called (main thread) when only what is displayed about the tracks changed, not their tags
    // (playback statistics and other metadb display hooks). nullptr stops watching.
    virtual void setDisplayChangeHandler(std::function<void()> onChange) { (void)onChange; }

    // The Details page: every track_property_provider's set_property() calls for the tracks, plus
    // unclaimed technical info. Delivered on the main thread (possibly before loadDetails() returns);
    // not delivered after cancelPending().
    virtual void loadDetails(std::function<void(std::vector<details::Entry>)> done) { done({}); }

    // Whether the window may save its frame, column widths and last tab.
    virtual bool persistWindowState() const { return true; }

    // The physical file of each track (load order); tracks of one file share their embedded pictures.
    virtual std::vector<std::string> trackPaths() const { return std::vector<std::string>(trackCount()); }

    // The local file the window stands for (its title bar's proxy icon, Command-click path menu and
    // drag-out): the file of a single track, as a POSIX path; empty for several tracks or a location
    // that is not a local file.
    virtual std::string representedFile() const {
        if (trackCount() != 1) return std::string();
        const std::vector<std::string> paths = trackPaths();
        return paths.empty() ? std::string() : local_file_path(paths.front());
    }

    // What names each track (load order) in a list of tracks, the "Edit Value" sheet: the host's title
    // display script (properties.titleDisplay, as in the window title), else the file name.
    virtual std::vector<std::string> trackTitles() {
        std::vector<std::string> out;
        for (auto& p : trackPaths()) {
            const size_t slash = p.find_last_of('/');
            out.push_back(slash == std::string::npos ? p : p.substr(slash + 1));
        }
        out.resize(trackCount());
        return out;
    }

    // Reads the tracks' embedded pictures off the main thread and delivers them on the main thread
    // (possibly before loadArt() returns). Not delivered after cancelPending().
    virtual void loadArt(std::function<void(ArtLoad)> done) { done(ArtLoad{std::vector<art::TrackArt>(trackCount()), {}}); }

    // Applies the per-file picture changes. `done` runs on the main thread.
    virtual void writeArt(std::vector<art::FileOps> files, std::function<void(WriteResult)> done) {
        WriteResult r;
        r.code = WriteResult::Errors;
        for (auto& f : files) r.errors.emplace_back(f.path, "Attached picture operations not supported");
        done(std::move(r));
    }

    // Evaluates a title formatting pattern for each track against the given (staged) fields, one
    // result per track. Returns false with a message in `error` when the pattern cannot be used.
    virtual bool formatFields(const std::string& pattern, const std::vector<TrackFields>& fields,
                              std::vector<std::string>& out, std::string& error) {
        (void)pattern;
        (void)fields;
        out.clear();
        error = "Title formatting is not available.";
        return false;
    }

    // The window is closing: abort reads still running for it.
    virtual void cancelPending() {}
};

}
