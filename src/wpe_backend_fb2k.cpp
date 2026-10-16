#include "wpe_entry.h"
#include "wpe_sdk.h"
#include "wpe_window.h"

namespace {

// fromHook: only display info changed (playback statistics and other metadb_display_field_provider
// hooks), not the tags.
class Watcher : public metadb_io_callback_dynamic_impl_base {
public:
    explicit Watcher(std::function<void(metadb_handle_list_cref, bool)> f) : m_f(std::move(f)) {}
    void on_changed_sorted(metadb_handle_list_cref items, bool fromHook) override {
        if (m_f) m_f(items, fromHook);
    }

private:
    std::function<void(metadb_handle_list_cref, bool)> m_f;
};

class Fb2kBackend : public wpe::Backend {
public:
    explicit Fb2kBackend(metadb_handle_list_cref items)
        : m_handles(items), m_abort(std::make_shared<abort_callback_impl>()) {}
    ~Fb2kBackend() override {
        m_abort->abort();
        dropWatcher();
    }

    size_t trackCount() const override { return m_handles.get_count(); }

    std::string windowTitle() override {
        if (m_handles.get_count() != 1) return wpe::window_title(m_handles.get_count(), {});
        pfc::string8 out;
        try {
            titleformat_object::ptr script;
            titleformat_compiler::get()->compile_safe_ex(script, wpe::title_display_format().c_str(), "%filename%");
            m_handles[0]->format_title(nullptr, out, script, nullptr);
        } catch (...) {
            out.reset();
        }
        if (out.is_empty()) out = pfc::string_filename_ext(m_handles[0]->get_path());
        return wpe::window_title(1, out.c_str());
    }

    wpe::Config config() override { return wpe::config_from_host(); }

    bool load(bool afterWrite, std::function<void(std::vector<wpe::TrackFields>, std::vector<wpe::rg::Info>)> done) override {
        std::vector<wpe::TrackFields> fields;
        std::vector<wpe::rg::Info> gains;
        if (wpe::read_cached(m_handles, afterWrite, fields, gains)) {
            done(std::move(fields), std::move(gains));
            return true;
        }
        // The read uses the window's abort token, like the Details and Artwork reads: closing the
        // window (cancelPending) stops get_full_info_ref on the remaining tracks.
        metadb_handle_list handles = m_handles;
        auto abort = m_abort;
        fb2k::inWorkerThread([handles, abort, done] {
            auto out = std::make_shared<std::vector<wpe::TrackFields>>();
            auto rg = std::make_shared<std::vector<wpe::rg::Info>>();
            bool ok = true;
            try {
                // Quitting foobar2000 stops the read too, as fb2k::mainAborter() did.
                abort_notify onQuit(fb2k::mainAborter(), [abort] { abort->abort(); });
                wpe::read_full(handles, *abort, *out, *rg);
            } catch (exception_aborted const&) {
                return;
            } catch (...) {
                if (abort->is_aborting()) return;
                ok = false;
            }
            fb2k::inMainThread([handles, abort, done, out, rg, ok] {
                if (abort->is_aborting()) return;
                if (!ok) wpe::read_cached(handles, false, *out, *rg);
                done(std::move(*out), std::move(*rg));
            });
        });
        return false;
    }

    void write(const wpe::Plan& plan, const std::vector<size_t>& tracks,
               std::function<void(wpe::WriteResult)> done) override {
        auto job = std::make_shared<wpe::WriteJob>();
        job->plan = plan;
        metadb_handle_list list;
        for (size_t t : tracks) {
            if (t >= m_handles.get_count()) continue;
            list.add_item(m_handles[t]);
            job->trackIndex[m_handles[t].get_ptr()] = t;
        }
        auto errors = std::make_shared<wpe::WriteErrors>();
        auto notify = fb2k::makeCompletionNotify([errors, done](unsigned code) {
            wpe::WriteResult r;
            r.errors = errors->take();
            if (code == metadb_io::update_info_aborted) r.code = wpe::WriteResult::Aborted;
            else if (code != metadb_io::update_info_success || !r.errors.empty()) r.code = wpe::WriteResult::Errors;
            done(std::move(r));
        });
        try {
            metadb_io_v2::get()->update_info_async(list, wpe::make_filter(job, errors), fb2k::get_main_window(),
                                                   metadb_io_v2::op_flag_partial_info_aware | metadb_io_v2::op_flag_delay_ui,
                                                   notify);
        } catch (std::exception const& e) {
            wpe::WriteResult r;
            r.code = wpe::WriteResult::Errors;
            r.errors.emplace_back("", std::string("Could not start writing tags: ") + e.what());
            done(std::move(r));
        }
    }

    void setChangeHandler(std::function<void()> onChange) override {
        m_onChange = std::move(onChange);
        updateWatcher();
    }

    void setDisplayChangeHandler(std::function<void()> onChange) override {
        m_onDisplayChange = std::move(onChange);
        updateWatcher();
    }

    // Details: every registered track_property_provider, as the host's Properties dialog does it.
    // Providers older than track_property_provider_v4 may only be called on the main thread, so they
    // run here and now; v4 and later (declared thread-safe and abortable) run in a worker thread with
    // one shared metadb v2 info source. The window's abort token stops them when it closes.
    void loadDetails(std::function<void(std::vector<wpe::details::Entry>)> done) override {
        auto providers = std::make_shared<wpe::DetailsProviders>(wpe::details_providers());
        auto entries = std::make_shared<std::vector<wpe::details::Entry>>();
        try {
            wpe::enumerate_details(providers->mainThread, m_handles, nullptr, *m_abort, *entries);
        } catch (exception_aborted const&) {
            return;
        }
        // Technical info that no provider claims (is_our_tech_info) and none listed: shown under
        // General. is_our_tech_info() of older providers is main-thread only, so it is asked here.
        auto tech = wpe::tech_fields(m_handles);
        std::vector<char> claimed;
        claimed.reserve(tech.size());
        for (auto& f : tech) claimed.push_back(wpe::tech_claimed(*providers, f.name.c_str()) ? 1 : 0);
        auto abort = m_abort;
        metadb_handle_list handles = m_handles;
        fb2k::inWorkerThread([handles, abort, providers, entries, tech, claimed, done] {
            try {
                if (!providers->anyThread.empty()) {
                    track_property_provider_v5_info_source_impl info(handles, *abort);
                    wpe::enumerate_details(providers->anyThread, handles, &info, *abort, *entries);
                }
            } catch (exception_aborted const&) {
                return;
            } catch (std::exception const&) {
            }
            fb2k::inMainThread([abort, entries, tech, claimed, done] {
                if (abort->is_aborting()) return;
                wpe::details::add_unclaimed(*entries, tech, [&](const std::string& name) {
                    for (size_t i = 0; i < tech.size(); ++i)
                        if (tech[i].name == name) return claimed[i] != 0;
                    return false;
                });
                done(std::move(*entries));
            });
        });
    }

    // Each track as the window title names a single one: properties.titleDisplay, else the file name.
    std::vector<std::string> trackTitles() override {
        titleformat_object::ptr script;
        try {
            titleformat_compiler::get()->compile_safe_ex(script, wpe::title_display_format().c_str(), "%filename%");
        } catch (...) {
            script.release();
        }
        std::vector<std::string> out;
        out.reserve(m_handles.get_count());
        for (size_t i = 0; i < m_handles.get_count(); ++i) {
            pfc::string8 text;
            try {
                if (script.is_valid()) m_handles[i]->format_title(nullptr, text, script, nullptr);
            } catch (...) {
                text.reset();
            }
            if (text.is_empty()) text = pfc::string_filename_ext(m_handles[i]->get_path());
            out.emplace_back(text.c_str());
        }
        return out;
    }

    std::vector<std::string> trackPaths() const override {
        std::vector<std::string> out;
        out.reserve(m_handles.get_count());
        for (size_t i = 0; i < m_handles.get_count(); ++i) out.emplace_back(m_handles[i]->get_path());
        return out;
    }

    // Pictures are read with album_art_extractor in a worker thread. The abort token belongs to the
    // window: cancelPending() (window closing) stops the read and drops its result.
    void loadArt(std::function<void(wpe::ArtLoad)> done) override {
        auto abort = m_abort;
        metadb_handle_list handles = m_handles;
        fb2k::inWorkerThread([handles, abort, done] {
            auto out = std::make_shared<wpe::ArtLoad>();
            try {
                wpe::read_art(handles, *abort, *out);
            } catch (exception_aborted const&) {
                return;
            } catch (std::exception const& e) {
                out->errors.emplace_back("", e.what());
            }
            fb2k::inMainThread([abort, done, out] {
                if (!abort->is_aborting()) done(std::move(*out));
            });
        });
    }

    // One threaded_process task (the host's progress UI appears only for slow writes) edits each
    // physical file once, then hands the files to metadb so playlists and album art views reload them.
    void writeArt(std::vector<wpe::art::FileOps> files, std::function<void(wpe::WriteResult)> done) override {
        struct Job {
            std::vector<wpe::art::FileOps> files;
            std::vector<std::pair<std::string, std::string>> errors;
            metadb_hint_list::ptr hints;
            metadb_handle_list touched;
            bool aborted = false;
        };
        auto job = std::make_shared<Job>();
        job->files = std::move(files);
        for (auto& f : job->files)
            for (size_t t : f.tracks)
                if (t < m_handles.get_count()) job->touched.add_item(m_handles[t]);
        job->touched.remove_duplicates();

        auto run = [job](threaded_process_status& status, abort_callback& abort) {
            const size_t n = job->files.size();
            try {
                for (size_t i = 0; i < n; ++i) {
                    const auto& f = job->files[i];
                    status.set_progress(i, n);
                    status.set_item_path(f.path.c_str());
                    abort.check();
                    try {
                        wpe::write_art(f, abort);
                    } catch (exception_aborted const&) {
                        throw;
                    } catch (std::exception const& e) {
                        job->errors.emplace_back(f.path, std::string("Attached picture editing failure: ") + e.what());
                        continue;
                    }
                    try {
                        input_info_reader::ptr reader;
                        input_entry::g_open_for_info_read(reader, nullptr, f.path.c_str(), abort);
                        job->hints->add_hint_reader(f.path.c_str(), reader, abort);
                    } catch (exception_aborted const&) {
                        throw;
                    } catch (std::exception const&) {
                        // The pictures were written; metadb just keeps its old file stats.
                    }
                }
                status.set_progress(n, n);
            } catch (exception_aborted const&) {
                job->aborted = true;
            }
        };
        auto finish = [job, done](threaded_process_callback::ctx_t, bool wasAborted) {
            // Main thread: apply the hints (metadb_io callbacks fire for the rewritten files), then
            // ask everything displaying these tracks to refresh, which reloads their album art.
            if (job->hints.is_valid()) job->hints->on_done();
            if (job->touched.get_count()) metadb_io::get()->dispatch_refresh(job->touched);
            wpe::WriteResult r;
            r.errors = std::move(job->errors);
            if (job->aborted || wasAborted) r.code = wpe::WriteResult::Aborted;
            else if (!r.errors.empty()) r.code = wpe::WriteResult::Errors;
            done(std::move(r));
        };
        try {
            job->hints = metadb_io_v2::get()->create_hint_list();
            threaded_process::get()->run_modeless(
                threaded_process_callback_lambda::create(nullptr, run, finish),
                threaded_process::flag_show_progress | threaded_process::flag_show_item | threaded_process::flag_show_abort |
                    threaded_process::flag_show_delayed,
                fb2k::get_main_window(), "Editing Attached Pictures");
        } catch (std::exception const& e) {
            wpe::WriteResult r;
            r.code = wpe::WriteResult::Errors;
            r.errors.emplace_back("", std::string("Could not start writing pictures: ") + e.what());
            done(std::move(r));
        }
    }

    bool formatFields(const std::string& pattern, const std::vector<wpe::TrackFields>& fields,
                      std::vector<std::string>& out, std::string& error) override {
        out.clear();
        titleformat_object::ptr script;
        if (!titleformat_compiler::get()->compile(script, pattern.c_str())) {
            error = "The pattern is not valid title formatting.";
            return false;
        }
        for (size_t t = 0; t < m_handles.get_count() && t < fields.size(); ++t) {
            // The track's technical info and location, with the window's staged fields as its tags.
            file_info_impl info;
            metadb_info_container::ptr cached;
            if (m_handles[t]->get_info_ref(cached) && cached.is_valid()) info.copy(cached->info());
            wpe::set_meta(info, fields[t]);
            pfc::string8 text;
            m_handles[t]->format_title_from_external_info(info, nullptr, text, script, nullptr);
            out.emplace_back(text.c_str());
        }
        return true;
    }

    void cancelPending() override { m_abort->abort(); }

private:
    // Unregistering a metadb_io callback looks the service up; after the host has shut its services
    // down that lookup aborts the process, so the watcher is abandoned instead.
    void dropWatcher() {
        if (!m_watcher) return;
        if (fb2k::are_services_available()) m_watcher.reset();
        else (void)m_watcher.release();
    }

    void updateWatcher() {
        dropWatcher();
        if (!m_onChange && !m_onDisplayChange) return;
        metadb_handle_list sorted = m_handles;
        sorted.sort_by_pointer();
        auto onChange = m_onChange;
        auto onDisplay = m_onDisplayChange;
        m_watcher = std::make_unique<Watcher>([sorted, onChange, onDisplay](metadb_handle_list_cref changed, bool fromHook) {
            const auto& f = fromHook ? onDisplay : onChange;
            if (!f) return;
            for (size_t i = 0; i < changed.get_count(); ++i) {
                if (metadb_handle_list_helper::bsearch_by_pointer(sorted, changed[i]) < sorted.get_count()) {
                    f();
                    return;
                }
            }
        });
    }

    metadb_handle_list m_handles;
    std::function<void()> m_onChange;
    std::function<void()> m_onDisplayChange;
    std::unique_ptr<Watcher> m_watcher;
    const std::shared_ptr<abort_callback_impl> m_abort;
};

}

void wpe_open_properties(metadb_handle_list_cref items) {
    metadb_handle_list list(items);
    list.remove_duplicates();
    if (list.get_count() == 0) return;
    wpe_show_properties_window(std::make_shared<Fb2kBackend>(list));
}
