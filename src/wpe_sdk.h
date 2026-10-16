#pragma once
// Bridge between the pure model and the foobar2000 SDK (no Cocoa).

#include "fb2k.h"
#include "wpe_art.h"
#include "wpe_backend.h"
#include "wpe_details.h"
#include "wpe_model.h"
#include "wpe_rg.h"

#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace wpe {

class FileInfoStore : public FieldStore {
public:
    explicit FileInfoStore(file_info& fi) : m_fi(fi) {}
    bool has(const std::string& name) const override;
    Values get(const std::string& name) const override;
    void remove(const std::string& name) override;
    void add(const std::string& name, const std::string& value) override;

private:
    file_info& m_fi;
};

TrackFields fields_from_info(const file_info& fi);

Config config_from_host();
std::string title_display_format();

struct WriteErrors {
    std::mutex lock;
    std::vector<std::pair<std::string, std::string>> items;
    std::vector<std::pair<std::string, std::string>> take();
};

struct WriteJob {
    Plan plan;
    std::map<const metadb_handle*, size_t> trackIndex;
};

file_info_filter::ptr make_filter(std::shared_ptr<const WriteJob> job, std::shared_ptr<WriteErrors> errors);

// Tags and ReplayGain of each track (`rg` receives one entry per track, like `out`).
bool read_cached(metadb_handle_list_cref items, bool afterWrite, std::vector<TrackFields>& out, std::vector<rg::Info>& rg);
void read_full(metadb_handle_list_cref items, abort_callback& abort, std::vector<TrackFields>& out, std::vector<rg::Info>& rg);

// ReplayGain: replaygain_info (invalid sentinels) <-> rg::Info (unset values).
rg::Info rg_from(const replaygain_info& info);
// Sets the plan's touched fields in `info` (get_replaygain/set_replaygain); true when it changed.
bool apply_rg(const rg::Plan& plan, file_info& info);

// Details: the registered track_property_provider services, split by whether they may be called
// off the main thread (track_property_provider_v4 and later) or not (v1-v3).
struct DetailsProviders {
    std::vector<track_property_provider::ptr> mainThread;
    std::vector<track_property_provider::ptr> anyThread;
};
DetailsProviders details_providers();
// Runs each provider through track_property_provider::enumerate_properties_helper(), which picks the
// newest interface it implements (v5 with metadb v2 records, v4 with abort, v3, v2, v1), and
// collects the set_property() calls. `info` may be null (the helper then reads the metadb).
void enumerate_details(const std::vector<track_property_provider::ptr>& providers, metadb_handle_list_cref items,
                       track_property_provider_v5_info_source* info, abort_callback& abort,
                       std::vector<details::Entry>& out);
// The tracks' technical info fields (main thread: metadb cache).
std::vector<details::TechField> tech_fields(metadb_handle_list_cref items);
// Whether any provider handles this technical info field itself (is_our_tech_info).
bool tech_claimed(const DetailsProviders& providers, const char* name);

// Replaces the meta part of `info` with `fields` (technical info is kept).
void set_meta(file_info& info, const TrackFields& fields);

// Artwork: art::Type index <-> album_art_ids (the SDK's own order: front, back, artist, disc, icon).
GUID art_guid(size_t type);
art::Picture picture_from(const album_art_data::ptr& data);
album_art_data::ptr data_from(const art::Picture& picture);
// Reads the embedded pictures of every track (worker thread). Each physical file is opened once,
// under a read lock. Files without pictures, or of formats that cannot carry them, read as empty.
void read_art(metadb_handle_list_cref items, abort_callback& abort, ArtLoad& out);
// Applies one file's picture changes (worker thread): write lock, album_art_editor, set/remove,
// commit. Throws on failure.
void write_art(const art::FileOps& file, abort_callback& abort);

}
