#include "wpe_sdk.h"

#include <cstring>

namespace wpe {

bool FileInfoStore::has(const std::string& name) const { return m_fi.meta_find(name.c_str()) != SIZE_MAX; }

Values FileInfoStore::get(const std::string& name) const {
    Values out;
    const size_t i = m_fi.meta_find(name.c_str());
    if (i == SIZE_MAX) return out;
    const size_t n = m_fi.meta_enum_value_count(i);
    for (size_t k = 0; k < n; ++k) out.emplace_back(m_fi.meta_enum_value(i, k));
    return out;
}

void FileInfoStore::remove(const std::string& name) { m_fi.meta_remove_field(name.c_str()); }

void FileInfoStore::add(const std::string& name, const std::string& value) { m_fi.meta_add(name.c_str(), value.c_str()); }

TrackFields fields_from_info(const file_info& fi) {
    TrackFields out;
    const size_t count = fi.meta_get_count();
    out.reserve(count);
    for (size_t i = 0; i < count; ++i) {
        FieldValues f;
        f.name = fi.meta_enum_name(i);
        const size_t n = fi.meta_enum_value_count(i);
        for (size_t k = 0; k < n; ++k) f.values.emplace_back(fi.meta_enum_value(i, k));
        out.push_back(std::move(f));
    }
    return out;
}

namespace {

std::string host_string(const char* key, const char* def) {
    try {
        auto v = fb2k::configStore::get()->getConfigString(key, def);
        if (v.is_valid()) return v->c_str();
    } catch (...) {
    }
    return def;
}

class wpe_filter : public file_info_filter_v2 {
public:
    wpe_filter(std::shared_ptr<const WriteJob> job, std::shared_ptr<WriteErrors> errors)
        : m_job(std::move(job)), m_errors(std::move(errors)) {}

    bool apply_filter(trackRef location, t_filestats, file_info& info) override {
        auto it = m_job->trackIndex.find(location.get_ptr());
        if (it == m_job->trackIndex.end()) return false;
        FileInfoStore store(info);
        const bool tags = apply(m_job->plan, it->second, store);
        const bool gain = apply_rg(m_job->plan.rg, info);
        return tags || gain;
    }
    filterStatus_t before_tag_update(const char*, file::ptr, abort_callback&) override { return filterProceed; }
    void after_tag_update(const char*, service_ptr_t<input_info_reader>, abort_callback&) override {}
    void after_all_tag_updates(abort_callback&) override {}
    bool filter_error(const char* location, const char* msg) override {
        std::lock_guard<std::mutex> g(m_errors->lock);
        m_errors->items.emplace_back(location ? location : "", msg ? msg : "");
        return true;
    }

private:
    const std::shared_ptr<const WriteJob> m_job;
    const std::shared_ptr<WriteErrors> m_errors;
};

}

std::vector<std::pair<std::string, std::string>> WriteErrors::take() {
    std::lock_guard<std::mutex> g(lock);
    auto out = std::move(items);
    items.clear();
    return out;
}

Config config_from_host() {
    return Config::parse(host_string("properties.standardFields", kDefaultStandardFields),
                         host_string("properties.multiLineFields", kDefaultMultiLineFields),
                         host_string("properties.multiValueFields", kDefaultMultiValueFields));
}

std::string title_display_format() { return host_string("properties.titleDisplay", "%title%"); }

file_info_filter::ptr make_filter(std::shared_ptr<const WriteJob> job, std::shared_ptr<WriteErrors> errors) {
    return fb2k::service_new<wpe_filter>(std::move(job), std::move(errors));
}

bool read_cached(metadb_handle_list_cref items, bool afterWrite, std::vector<TrackFields>& out, std::vector<rg::Info>& rg) {
    out.clear();
    out.reserve(items.get_count());
    rg.clear();
    rg.reserve(items.get_count());
    bool complete = true;
    for (size_t i = 0; i < items.get_count(); ++i) {
        metadb_info_container::ptr info;
        const bool ok = afterWrite ? items[i]->get_async_info_ref(info) : items[i]->get_info_ref(info);
        if (!ok || info.is_empty()) {
            complete = false;
            out.emplace_back();
            rg.emplace_back();
            continue;
        }
        if (info->isInfoPartial()) complete = false;
        out.push_back(fields_from_info(info->info()));
        rg.push_back(rg_from(info->info().get_replaygain()));
    }
    return complete;
}

void read_full(metadb_handle_list_cref items, abort_callback& abort, std::vector<TrackFields>& out, std::vector<rg::Info>& rg) {
    out.clear();
    out.reserve(items.get_count());
    rg.clear();
    rg.reserve(items.get_count());
    for (size_t i = 0; i < items.get_count(); ++i) {
        metadb_info_container::ptr info;
        try {
            info = items[i]->get_full_info_ref(abort);
        } catch (std::exception const&) {
            if (abort.is_aborting()) throw;
            info = items[i]->get_info_ref();
        }
        out.push_back(info.is_valid() ? fields_from_info(info->info()) : TrackFields{});
        rg.push_back(info.is_valid() ? rg_from(info->info().get_replaygain()) : rg::Info{});
    }
}

rg::Info rg_from(const replaygain_info& info) {
    rg::Info out;
    if (info.have_track_gain()) out.values[rg::TrackGain] = info.m_track_gain;
    if (info.have_track_peak()) out.values[rg::TrackPeak] = info.m_track_peak;
    if (info.have_album_gain()) out.values[rg::AlbumGain] = info.m_album_gain;
    if (info.have_album_peak()) out.values[rg::AlbumPeak] = info.m_album_peak;
    return out;
}

bool apply_rg(const rg::Plan& plan, file_info& info) {
    if (plan.empty()) return false;
    rg::Info values = rg_from(info.get_replaygain());
    if (!rg::apply(plan, values)) return false;
    // Only the touched fields change; the others keep the file's own values.
    replaygain_info out = info.get_replaygain();
    const auto& v = values.values;
    out.m_track_gain = v[rg::TrackGain] ? *v[rg::TrackGain] : replaygain_info::gain_invalid;
    out.m_track_peak = v[rg::TrackPeak] ? *v[rg::TrackPeak] : replaygain_info::peak_invalid;
    out.m_album_gain = v[rg::AlbumGain] ? *v[rg::AlbumGain] : replaygain_info::gain_invalid;
    out.m_album_peak = v[rg::AlbumPeak] ? *v[rg::AlbumPeak] : replaygain_info::peak_invalid;
    info.set_replaygain(out);
    return true;
}

namespace {

// Collects set_property() calls; every group is wanted.
class DetailsCallback : public track_property_callback_v2 {
public:
    explicit DetailsCallback(std::vector<details::Entry>& out) : m_out(out) {}
    void set_property(const char* group, double priority, const char* name, const char* value) override {
        m_out.push_back(details::Entry{group ? group : "", priority, name ? name : "", value ? value : ""});
    }
    bool is_group_wanted(const char*) override { return true; }

private:
    std::vector<details::Entry>& m_out;
};

}

DetailsProviders details_providers() {
    DetailsProviders out;
    for (auto ptr : track_property_provider::enumerate()) {
        track_property_provider_v4::ptr v4;
        if (v4 &= ptr) out.anyThread.push_back(ptr);
        else out.mainThread.push_back(ptr);
    }
    return out;
}

void enumerate_details(const std::vector<track_property_provider::ptr>& providers, metadb_handle_list_cref items,
                       track_property_provider_v5_info_source* info, abort_callback& abort,
                       std::vector<details::Entry>& out) {
    DetailsCallback callback(out);
    for (auto& p : providers) {
        abort.check();
        try {
            if (info) p->enumerate_properties_helper(items, info, callback, abort);
            else p->enumerate_properties_helper(items, nullptr, callback, abort);
        } catch (exception_aborted const&) {
            throw;
        } catch (std::exception const&) {
            // One failing provider does not hide the others' lines.
        }
    }
}

std::vector<details::TechField> tech_fields(metadb_handle_list_cref items) {
    std::vector<std::vector<std::pair<std::string, std::string>>> tracks;
    tracks.reserve(items.get_count());
    for (size_t i = 0; i < items.get_count(); ++i) {
        tracks.emplace_back();
        metadb_info_container::ptr info;
        if (!items[i]->get_info_ref(info) || info.is_empty()) continue;
        const file_info& fi = info->info();
        for (size_t k = 0; k < fi.info_get_count(); ++k) tracks.back().emplace_back(fi.info_enum_name(k), fi.info_enum_value(k));
    }
    return details::merge_tech(tracks);
}

bool tech_claimed(const DetailsProviders& providers, const char* name) {
    for (auto* list : {&providers.mainThread, &providers.anyThread})
        for (auto& p : *list)
            if (p->is_our_tech_info(name)) return true;
    return false;
}

void set_meta(file_info& info, const TrackFields& fields) {
    info.meta_remove_all();
    for (auto& f : fields)
        for (auto& v : f.values) info.meta_add(f.name.c_str(), v.c_str());
}

GUID art_guid(size_t type) {
    // album_art_ids::query_type() uses the same order as art::Type (album_art.cpp).
    return type < album_art_ids::num_types() ? album_art_ids::query_type(type) : pfc::guid_null;
}

art::Picture picture_from(const album_art_data::ptr& data) {
    if (data.is_empty()) return nullptr;
    return art::make_picture(data->data(), data->size());
}

album_art_data::ptr data_from(const art::Picture& picture) {
    if (!picture) return nullptr;
    return album_art_data_impl::g_create(picture->data(), picture->size());
}

// A picture type the file simply does not have, or a format without pictures: not an error.
static bool art_entry_absent(std::exception const& e) {
    const char* m = e.what();
    if (!m) return false;
    auto is = [m](std::exception const& known) { return std::strcmp(m, known.what()) == 0; };
    return is(exception_album_art_not_found()) || is(exception_album_art_unsupported_entry()) ||
           is(exception_album_art_unsupported_format()) || is(exception_io_unsupported_format());
}

void read_art(metadb_handle_list_cref items, abort_callback& abort, ArtLoad& out) {
    out.tracks.assign(items.get_count(), {});
    out.errors.clear();
    std::map<std::string, size_t> first;  // physical file -> first track read from it
    art::PictureCache cache;
    for (size_t i = 0; i < items.get_count(); ++i) {
        abort.check();
        const char* path = items[i]->get_path();
        auto [it, fresh] = first.emplace(path, i);
        if (!fresh) {
            out.tracks[i] = out.tracks[it->second];
            continue;
        }
        try {
            // A read lock, as the SDK sample does: a pending tag write (file_lock_manager write lock)
            // finishes before we read, and we never read a half-written file.
            auto lock = file_lock_manager::get()->acquire_read(path, abort);
            album_art_extractor_instance::ptr extractor = album_art_extractor::g_open(nullptr, path, abort);
            for (size_t type = 0; type < art::TypeCount; ++type) {
                try {
                    album_art_data::ptr data;
                    if (extractor->query(art_guid(type), data, abort))
                        out.tracks[i].pictures[type] = cache.intern(picture_from(data));
                } catch (exception_album_art_unsupported_entry const&) {
                } catch (exception_album_art_not_found const&) {
                } catch (exception_aborted const&) {
                    throw;
                } catch (std::exception const& e) {
                    // The host throws its own copy of exception_album_art_not_found, which does not
                    // always match ours by type across the image boundary; a missing picture type is
                    // normal, so recognise it by its message and keep reading the other types.
                    if (!art_entry_absent(e)) throw;
                }
            }
        } catch (exception_aborted const&) {
            throw;
        } catch (exception_album_art_not_found const&) {
        } catch (exception_album_art_unsupported_format const&) {
        } catch (exception_io_unsupported_format const&) {
        } catch (std::exception const& e) {
            if (art_entry_absent(e)) continue;
            out.errors.emplace_back(path, e.what());
        }
    }
}

void write_art(const art::FileOps& file, abort_callback& abort) {
    const char* path = file.path.c_str();
    // Writing with low-level APIs requires a write lock (file_lock_manager.h); it makes playback of
    // this file release and reopen it around the update instead of failing or reading garbage.
    auto lock = file_lock_manager::get()->acquire_write(path, abort);
    album_art_editor_instance::ptr editor = album_art_editor::g_open(nullptr, path, abort);
    for (auto& op : file.ops) {
        if (op.picture) editor->set(art_guid(op.type), data_from(op.picture), abort);
        else editor->remove(art_guid(op.type));
    }
    // Not abortable: an interrupted commit could leave a damaged file.
    editor->commit(fb2k::noAbort);
}

}
