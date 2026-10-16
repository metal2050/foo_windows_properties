// The Artwork page model (src/wpe_art.*): merging N tracks, staging, the per-file write plan, format
// sniffing, header dimensions and size text. No SDK, no Cocoa.

#include "test.h"
#include "../src/wpe_art.h"

#include <initializer_list>

using namespace wpe::art;

namespace {

Bytes bytes(std::initializer_list<int> v) {
    Bytes out;
    for (int b : v) out.push_back(static_cast<uint8_t>(b));
    return out;
}

void put_be32(Bytes& b, size_t at, uint32_t v) {
    b[at] = uint8_t(v >> 24);
    b[at + 1] = uint8_t(v >> 16);
    b[at + 2] = uint8_t(v >> 8);
    b[at + 3] = uint8_t(v);
}

void put_le(Bytes& b, size_t at, uint32_t v, int n) {
    for (int i = 0; i < n; ++i) b[at + size_t(i)] = uint8_t(v >> (8 * i));
}

Bytes png(uint32_t w, uint32_t h, size_t pad = 0) {
    Bytes b = bytes({0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 'I', 'H', 'D', 'R'});
    b.resize(33 + pad, 0);
    put_be32(b, 16, w);
    put_be32(b, 20, h);
    return b;
}

// SOI, an APP0 segment, then SOF2 (progressive) with the size.
Bytes jpeg(uint32_t w, uint32_t h) {
    Bytes b = bytes({0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x06, 'J', 'F', 'I', 'F', 0xFF, 0xFF, 0xC2, 0x00, 0x11, 0x08,
                     0, 0, 0, 0, 0x03});
    b[16] = uint8_t(h >> 8);
    b[17] = uint8_t(h);
    b[18] = uint8_t(w >> 8);
    b[19] = uint8_t(w);
    b.resize(40, 0);
    return b;
}

Bytes gif(uint32_t w, uint32_t h) {
    Bytes b = bytes({'G', 'I', 'F', '8', '9', 'a', 0, 0, 0, 0, 0, 0, 0});
    put_le(b, 6, w, 2);
    put_le(b, 8, h, 2);
    return b;
}

Bytes bmp(int32_t w, int32_t h) {
    Bytes b(54, 0);
    b[0] = 'B';
    b[1] = 'M';
    put_le(b, 14, 40, 4);
    put_le(b, 18, uint32_t(w), 4);
    put_le(b, 22, uint32_t(h), 4);
    return b;
}

Bytes webp(const char* chunk) {
    Bytes b(32, 0);
    const char* riff = "RIFF\0\0\0\0WEBP";
    for (int i = 0; i < 12; ++i) b[size_t(i)] = uint8_t(riff[i]);
    for (int i = 0; i < 4; ++i) b[size_t(12 + i)] = uint8_t(chunk[i]);
    return b;
}

Picture pic(Bytes b) { return make_picture(std::move(b)); }

TrackArt art(std::initializer_list<std::pair<size_t, Picture>> pictures) {
    TrackArt t;
    for (auto& [type, p] : pictures) t.pictures[type] = p;
    return t;
}

}

TEST(art_rows_are_in_windows_order) {
    CHECK_EQ(size_t(TypeCount), size_t(5));
    CHECK_EQ(std::string(type_label(FrontCover)), std::string("Front Cover"));
    CHECK_EQ(std::string(type_label(BackCover)), std::string("Back Cover"));
    CHECK_EQ(std::string(type_label(Artist)), std::string("Artist"));
    CHECK_EQ(std::string(type_label(Disc)), std::string("Disc"));
    CHECK_EQ(std::string(type_label(Icon)), std::string("Icon"));
    CHECK_EQ(type_list({FrontCover, Disc}), std::string("Front Cover, Disc"));
}

TEST(art_format_sniffing) {
    CHECK(sniff(jpeg(1, 1)) == Format::JPEG);
    CHECK(sniff(png(1, 1)) == Format::PNG);
    CHECK(sniff(gif(1, 1)) == Format::GIF);
    CHECK(sniff(bmp(1, 1)) == Format::BMP);
    CHECK(sniff(webp("VP8 ")) == Format::WebP);
    CHECK(sniff(bytes({'I', 'I', '*', 0, 8, 0, 0, 0})) == Format::TIFF);
    CHECK(sniff(bytes({'M', 'M', 0, '*', 0, 0, 0, 8})) == Format::TIFF);
    CHECK(sniff(bytes({0, 0, 1, 0, 1, 0, 16, 16})) == Format::ICO);
    CHECK(sniff(bytes({0, 0, 0, 24, 'f', 't', 'y', 'p', 'h', 'e', 'i', 'c', 0, 0, 0, 0, 'm', 'i', 'f', '1', 'h', 'e', 'i', 'c'})) ==
          Format::HEIF);
    CHECK(sniff(bytes({0, 0, 0, 20, 'f', 't', 'y', 'p', 'a', 'v', 'i', 'f', 0, 0, 0, 0, 'm', 'i', 'f', '1'})) == Format::AVIF);
    CHECK(sniff(bytes({'h', 'e', 'l', 'l', 'o'})) == Format::Unknown);
    CHECK(sniff(Bytes{}) == Format::Unknown);
    CHECK(sniff(bytes({0xFF, 0xD8})) == Format::Unknown);
    CHECK_EQ(std::string(format_name(Format::JPEG)), std::string("JPEG"));
    CHECK_EQ(std::string(format_name(Format::PNG)), std::string("PNG"));
    CHECK_EQ(std::string(format_name(Format::WebP)), std::string("WebP"));
    CHECK_EQ(std::string(format_name(Format::Unknown)), std::string(""));
    CHECK_EQ(std::string(format_extension(Format::JPEG)), std::string("jpg"));
    CHECK_EQ(std::string(format_uti(Format::PNG)), std::string("public.png"));
    CHECK(attachable(Format::JPEG) && attachable(Format::PNG) && attachable(Format::GIF) && attachable(Format::WebP) &&
          attachable(Format::BMP));
    CHECK(!attachable(Format::TIFF) && !attachable(Format::HEIF) && !attachable(Format::Unknown));
}

TEST(art_dimensions_from_headers) {
    CHECK(dimensions(png(600, 600)) == (Dimensions{600, 600}));
    CHECK(dimensions(jpeg(1425, 1417)) == (Dimensions{1425, 1417}));
    CHECK(dimensions(gif(320, 200)) == (Dimensions{320, 200}));
    CHECK(dimensions(bmp(64, -48)) == (Dimensions{64, 48}));
    Bytes lossy = webp("VP8 ");
    lossy[23] = 0x9D;
    lossy[24] = 0x01;
    lossy[25] = 0x2A;
    put_le(lossy, 26, 500, 2);
    put_le(lossy, 28, 0x4000 | 300, 2);  // the top two bits are a scale, not size
    CHECK(dimensions(lossy) == (Dimensions{500, 300}));
    Bytes lossless = webp("VP8L");
    lossless[20] = 0x2F;
    put_le(lossless, 21, (640 - 1) | ((480 - 1) << 14), 4);
    CHECK(dimensions(lossless) == (Dimensions{640, 480}));
    Bytes extended = webp("VP8X");
    put_le(extended, 24, 1000 - 1, 3);
    put_le(extended, 27, 800 - 1, 3);
    CHECK(dimensions(extended) == (Dimensions{1000, 800}));
    CHECK(!dimensions(bytes({'I', 'I', '*', 0})).valid());
    CHECK(!dimensions(Bytes{0xFF, 0xD8, 0xFF, 0xD9}).valid());
    CHECK(!dimensions(png(0, 0)).valid());
    CHECK_EQ(dimensions_text({600, 600}), std::string("600x600"));
    CHECK_EQ(dimensions_text({}), std::string(""));
}

TEST(art_size_text_is_windows_style) {
    CHECK_EQ(size_text(0), std::string("0 KB"));
    CHECK_EQ(size_text(1), std::string("1 KB"));
    CHECK_EQ(size_text(1024), std::string("1 KB"));
    CHECK_EQ(size_text(1025), std::string("2 KB"));
    CHECK_EQ(size_text(500000), std::string("489 KB"));
    CHECK_EQ(size_text(1024 * 1024 - 1), std::string("1024 KB"));
    CHECK_EQ(size_text(1024 * 1024), std::string("1 MB"));
    CHECK_EQ(size_text(1500000), std::string("1.43 MB"));
    CHECK_EQ(size_text(uint64_t(12.34 * 1024 * 1024)), std::string("12.3 MB"));
    CHECK_EQ(size_text(uint64_t(123.9 * 1024 * 1024)), std::string("123 MB"));
    CHECK_EQ(size_text(uint64_t(5) * 1024 * 1024 * 1024), std::string("5 GB"));
}

TEST(art_merge_present_mixed_absent) {
    const Picture a = pic(png(10, 10));
    const Picture aCopy = pic(png(10, 10));  // same bytes, another buffer
    const Picture b = pic(png(20, 20));
    Table t;
    CHECK(!t.loaded());
    t.load({art({{FrontCover, a}, {BackCover, a}, {Disc, a}}), art({{FrontCover, aCopy}, {BackCover, b}})});
    CHECK(t.loaded());
    CHECK_EQ(t.trackCount(), size_t(2));
    CHECK(t.slot(FrontCover).state() == State::Present);
    CHECK(same(t.slot(FrontCover).picture(), a));
    CHECK(t.slot(BackCover).state() == State::Mixed);
    CHECK(!t.slot(BackCover).picture());
    CHECK(t.slot(Disc).state() == State::Mixed);  // one track has it, the other does not
    CHECK(t.slot(Artist).state() == State::Absent);
    CHECK(t.slot(Icon).state() == State::Absent);
    CHECK(!t.dirty());

    Table none;
    none.load({});
    CHECK(none.slot(FrontCover).state() == State::Absent);
}

TEST(art_details_lines) {
    Table t;
    Bytes big = png(600, 600, 500000 - 33);
    t.load({art({{FrontCover, pic(big)}, {BackCover, pic(png(1, 1))}}), art({{FrontCover, pic(big)}})});
    const Details front = t.details(FrontCover);
    CHECK_EQ(front.lines, (std::vector<std::string>{"489 KB", "600x600", "PNG"}));
    CHECK(!front.mixed && !front.absent && !front.pending);
    const Details back = t.details(BackCover);
    CHECK(back.mixed);
    CHECK_EQ(back.lines, (std::vector<std::string>{kMultipleValues}));
    const Details artist = t.details(Artist);
    CHECK(artist.absent);
    CHECK_EQ(artist.lines, (std::vector<std::string>{kNotPresent}));
    CHECK_EQ(std::string(kNotPresent), std::string("\xC2\xAB" "not present" "\xC2\xBB"));

    // A format the header parser does not read takes its dimensions from the caller.
    Table tiff;
    tiff.load({art({{Icon, pic(bytes({'I', 'I', '*', 0, 8, 0, 0, 0}))}})});
    CHECK_EQ(tiff.details(Icon).lines, (std::vector<std::string>{"1 KB", "TIFF"}));
    CHECK_EQ(tiff.details(Icon, {32, 32}).lines, (std::vector<std::string>{"1 KB", "32x32", "TIFF"}));
}

TEST(art_staging_and_discard) {
    const Picture a = pic(png(10, 10));
    const Picture b = pic(jpeg(30, 40));
    Table t;
    CHECK(!t.stageSet(FrontCover, a));  // nothing loaded yet
    t.load({art({{FrontCover, a}})});

    CHECK(!t.stageSet(FrontCover, pic(png(10, 10))));  // same bytes as loaded: no change
    CHECK(!t.dirty());
    CHECK(t.stageSet(BackCover, b));
    CHECK(t.slot(BackCover).state() == State::Present);
    CHECK(t.details(BackCover).pending);
    CHECK_EQ(t.details(BackCover).lines, (std::vector<std::string>{"1 KB", "30x40", "JPEG"}));
    CHECK(!t.stageSet(BackCover, b));  // already staged
    CHECK(t.stageRemove(FrontCover));
    CHECK(t.slot(FrontCover).state() == State::Absent);
    CHECK(t.details(FrontCover).absent && t.details(FrontCover).pending);
    CHECK(!t.stageRemove(FrontCover));
    CHECK(!t.stageRemove(Artist));  // nothing to remove
    CHECK_EQ(t.pendingTypes(), (std::vector<size_t>{FrontCover, BackCover}));
    CHECK(t.dirty());

    // Setting the loaded picture again, or removing a staged addition, undoes the staging.
    CHECK(t.stageSet(FrontCover, pic(png(10, 10))));
    CHECK(!t.slot(FrontCover).isPending());
    CHECK(t.stageRemove(BackCover));
    CHECK(!t.slot(BackCover).isPending());
    CHECK(!t.dirty());

    CHECK(t.stageSet(Disc, b));
    t.discard();
    CHECK(!t.dirty());
    CHECK(t.slot(Disc).state() == State::Absent);

    // Reloading drops staged edits.
    CHECK(t.stageSet(Disc, b));
    t.load({art({})});
    CHECK(!t.dirty());
}

TEST(art_plan_groups_subsongs_and_skips_matching_files) {
    const Picture a = pic(png(10, 10));
    const Picture b = pic(png(20, 20));
    Table t;
    // Tracks 0 and 2 are subsongs of one CUE image; track 1 is its own file and already has `b`.
    t.load({art({{FrontCover, a}, {Disc, a}}), art({{FrontCover, b}}), art({{FrontCover, a}, {Disc, a}})});
    const std::vector<std::string> paths{"file:///cd.flac", "file:///single.flac", "file:///cd.flac"};
    CHECK(t.plan(paths).empty());

    CHECK(t.stageSet(FrontCover, b));
    auto plan = t.plan(paths);
    CHECK_EQ(plan.size(), size_t(1));
    if (plan.size() == 1) {
        CHECK_EQ(plan[0].path, std::string("file:///cd.flac"));
        CHECK_EQ(plan[0].tracks, (std::vector<size_t>{0, 2}));
        CHECK_EQ(plan[0].ops.size(), size_t(1));
        if (!plan[0].ops.empty()) {
            CHECK_EQ(plan[0].ops[0].type, size_t(FrontCover));
            CHECK(same(plan[0].ops[0].picture, b));
        }
    }

    CHECK(t.stageRemove(Disc));
    plan = t.plan(paths);
    CHECK_EQ(plan.size(), size_t(1));  // single.flac has no disc picture and already has `b`
    if (plan.size() == 1) {
        CHECK_EQ(plan[0].ops.size(), size_t(2));
        if (plan[0].ops.size() == 2) {
            CHECK_EQ(plan[0].ops[1].type, size_t(Disc));
            CHECK(!plan[0].ops[1].picture);
        }
    }

    // Untouched types are never written, whatever the files hold.
    for (auto& f : plan)
        for (auto& op : f.ops) CHECK(op.type == FrontCover || op.type == Disc);

    CHECK(t.stageSet(Icon, a));
    plan = t.plan(paths);
    CHECK_EQ(plan.size(), size_t(2));
    if (plan.size() == 2) {
        CHECK_EQ(plan[1].path, std::string("file:///single.flac"));
        CHECK_EQ(plan[1].ops.size(), size_t(1));
    }
}

TEST(art_identical_pictures_share_one_buffer) {
    PictureCache cache;
    const Picture a = cache.intern(pic(png(10, 10)));
    const Picture a2 = cache.intern(pic(png(10, 10)));
    const Picture b = cache.intern(pic(png(20, 20)));
    CHECK(a == a2);  // the same object, so comparing tracks is a pointer compare
    CHECK(a != b);
    CHECK_EQ(cache.size(), size_t(2));
    CHECK(!cache.intern(nullptr));
}

TEST(art_group_by_file_keeps_first_appearance_order) {
    const auto groups = group_by_file({"b", "a", "b", "c", "a"});
    CHECK_EQ(groups.size(), size_t(3));
    if (groups.size() == 3) {
        CHECK_EQ(groups[0].path, std::string("b"));
        CHECK_EQ(groups[0].tracks, (std::vector<size_t>{0, 2}));
        CHECK_EQ(groups[1].tracks, (std::vector<size_t>{1, 4}));
        CHECK_EQ(groups[2].tracks, (std::vector<size_t>{3}));
    }
    CHECK(group_by_file({}).empty());
}

TEST(art_commit_makes_written_edits_the_loaded_state) {
    const Picture a = pic(png(10, 10));
    const Picture b = pic(jpeg(30, 40));
    Table t;
    t.commit();  // nothing loaded: no-op
    CHECK(!t.loaded());
    t.load({art({{FrontCover, a}, {Disc, a}}), art({{FrontCover, b}, {Disc, a}})});
    CHECK(t.slot(FrontCover).state() == State::Mixed);
    CHECK(t.stageSet(FrontCover, b));
    CHECK(t.stageRemove(Disc));
    t.commit();
    CHECK(!t.dirty());
    CHECK(t.slot(FrontCover).state() == State::Present);
    CHECK(same(t.slot(FrontCover).picture(), b));
    CHECK(t.slot(Disc).state() == State::Absent);
    CHECK(same(t.track(0).pictures[FrontCover], b));
    CHECK(!t.track(1).pictures[Disc]);
    CHECK(t.plan({"x", "y"}).empty());  // nothing left to write
}

TEST(art_failed_files_counts_physical_files_not_entries) {
    // One read-only FLAC: its tags and its picture both failed.
    CHECK_EQ(failed_files({{"file:///a.flac", "Access denied"}, {"file:///a.flac", "Attached picture editing failure"}}),
             size_t(1));
    // A CUE image with 12 selected tracks reports one entry per track.
    Errors cue;
    for (int i = 0; i < 12; ++i) cue.emplace_back("file:///image.flac", "Access denied");
    CHECK_EQ(failed_files(cue), size_t(1));
    CHECK_EQ(unique_errors(cue).size(), size_t(1));
    CHECK_EQ(failed_files({{"/a.flac", "x"}, {"file:///a.flac", "y"}, {"file:///b.flac", "x"}, {"", "general"}}), size_t(2));
    CHECK_EQ(failed_files({{"", "Could not start writing tags"}}), size_t(0));
    const Errors mixed{{"a", "1"}, {"a", "2"}, {"a", "1"}, {"b", "1"}};
    CHECK(unique_errors(mixed) == (Errors{{"a", "1"}, {"a", "2"}, {"b", "1"}}));
}

TEST(art_conversion_keeps_attachable_bytes_and_photos_become_jpeg) {
    // What foobar2000 attaches is never re-encoded, transparency or not.
    for (Format f : {Format::JPEG, Format::PNG, Format::GIF, Format::WebP, Format::BMP}) {
        CHECK(conversion_for(f, false) == Conversion::Keep);
        CHECK(conversion_for(f, true) == Conversion::Keep);
    }
    // HEIF/AVIF photos are already lossy: JPEG, unless they have transparency.
    CHECK(conversion_for(Format::HEIF, false) == Conversion::JPEG);
    CHECK(conversion_for(Format::AVIF, false) == Conversion::JPEG);
    CHECK(conversion_for(Format::HEIF, true) == Conversion::PNG);
    CHECK(conversion_for(Format::AVIF, true) == Conversion::PNG);
    // Everything else is converted losslessly.
    for (Format f : {Format::TIFF, Format::ICO, Format::Unknown}) {
        CHECK(conversion_for(f, false) == Conversion::PNG);
        CHECK(conversion_for(f, true) == Conversion::PNG);
    }
    CHECK(kJPEGQuality > 0.85 && kJPEGQuality < 0.97);
    CHECK_EQ(file_name(FrontCover, Format::JPEG), std::string("Front Cover.jpg"));
    CHECK_EQ(file_name(Disc, Format::PNG), std::string("Disc.png"));
    CHECK_EQ(file_name(Icon, Format::Unknown), std::string("Icon.bin"));
}

TEST(art_description_is_what_voiceover_reads) {
    Table t;
    const Picture a = pic(png(600, 600, 300 * 1024));
    t.load({art({{FrontCover, a}, {BackCover, a}}), art({{FrontCover, a}, {BackCover, pic(png(1, 1))}})});
    CHECK_EQ(t.description(FrontCover), std::string("Front Cover, 600\xC3\x97" "600 PNG, 301 KB"));
    CHECK_EQ(t.description(BackCover), std::string("Back Cover, multiple values"));
    CHECK_EQ(t.description(Disc), std::string("Disc, not present"));
    // Dimensions the header does not give come from the decoder.
    Bytes tiffBytes = bytes({'I', 'I', '*', 0, 8, 0, 0, 0});
    t.stageSet(Icon, pic(tiffBytes));
    CHECK_EQ(t.description(Icon), std::string("Icon, TIFF, 1 KB, pending"));
    CHECK_EQ(t.description(Icon, {32, 16}), std::string("Icon, 32\xC3\x97" "16 TIFF, 1 KB, pending"));
    t.stageRemove(FrontCover);
    CHECK_EQ(t.description(FrontCover), std::string("Front Cover, not present, pending"));
    CHECK_EQ(t.description(TypeCount), std::string(""));
}
