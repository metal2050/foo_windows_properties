#include "test.h"
#include "../src/wpe_model.h"

#include <algorithm>
#include <cctype>

using namespace wpe;

namespace {

const std::string kMV = std::string(kMultipleValues) + " ";

TrackFields tf(std::initializer_list<FieldValues> f) { return TrackFields(f); }

Table make(const std::vector<TrackFields>& tracks) {
    Table t;
    t.load(tracks, Config::defaults());
    return t;
}

size_t idx(const Table& t, const char* field) { return t.find(field); }

Values values_after(const Table& t, size_t track, const char* field) {
    MemoryStore s(t.loadedFields(track));
    apply(t.plan(), track, s);
    return s.get(field);
}

bool has_after(const Table& t, size_t track, const char* field) {
    MemoryStore s(t.loadedFields(track));
    apply(t.plan(), track, s);
    return s.has(field);
}

}

TEST(string_helpers) {
    CHECK_EQ(upper_ascii("Album Artist"), std::string("ALBUM ARTIST"));
    CHECK(iequals("artist", "ARTIST"));
    CHECK(!iequals("artist", "ARTISTS"));
    CHECK(icompare("abc", "ABD") < 0);
    CHECK(icompare("B", "a") > 0);
    CHECK_EQ(icompare("Same", "sAME"), 0);
    CHECK_EQ(trim("  x y \t\n"), std::string("x y"));
    CHECK_EQ(join({"a", "b", "c"}), std::string("a; b; c"));
    CHECK_EQ(join({}), std::string(""));
    CHECK_EQ(split_multi(" a ;b;; ;c "), (Values{"a", "b", "c"}));
    CHECK_EQ(split_multi("   "), Values{});
    CHECK_EQ(single_line("one\r\ntwo\nthree\rfour"), std::string("one \xE2\x86\xB5 two \xE2\x86\xB5 three \xE2\x86\xB5 four"));
    CHECK(has_newline("a\nb"));
    CHECK(!has_newline("ab"));
    CHECK_EQ(capitalize_ascii("the beatles - let it be (remastered)"), std::string("The Beatles - Let It Be (Remastered)"));
    CHECK_EQ(capitalize_ascii("AC/DC don't stop"), std::string("AC/DC Don't Stop"));
    CHECK(valid_field_name("ALBUM ARTIST"));
    CHECK(!valid_field_name(""));
    CHECK(!valid_field_name("A=B"));
    CHECK(!valid_field_name("A\tB"));
}

// The window title, Mac style: an em dash, "N Tracks" in title case; and which locations get a proxy icon.
TEST(window_title_and_local_file_path) {
    CHECK_EQ(window_title(1, "Song"), std::string("Properties \xE2\x80\x94 Song"));
    CHECK_EQ(window_title(2, ""), std::string("Properties \xE2\x80\x94 2 Tracks"));
    CHECK_EQ(window_title(250, "ignored"), std::string("Properties \xE2\x80\x94 250 Tracks"));
    CHECK_EQ(window_title(0, ""), std::string("Properties \xE2\x80\x94 0 Tracks"));
    CHECK_EQ(local_file_path("file:///Music/Example/a b.flac"), std::string("/Music/Example/a b.flac"));
    CHECK_EQ(local_file_path("file:///Volumes/NAS/%20odd%.mp3"), std::string("/Volumes/NAS/%20odd%.mp3"));  // raw, not URL-escaped
    CHECK_EQ(local_file_path("file://"), std::string(""));
    CHECK_EQ(local_file_path("file://relative/x.flac"), std::string(""));
    CHECK_EQ(local_file_path("unpack://zip|10|file:///a.zip|b.flac"), std::string(""));
    CHECK_EQ(local_file_path("http://example.com/stream"), std::string(""));
    CHECK_EQ(local_file_path("cdda://track01"), std::string(""));
    CHECK_EQ(local_file_path(""), std::string(""));
}

TEST(host_config_strings_parse) {
    auto std_fields = parse_standard_fields(kDefaultStandardFields);
    CHECK_EQ(std_fields.size(), size_t(13));
    CHECK_EQ(std_fields.front().label, std::string("Artist Name"));
    CHECK_EQ(std_fields.front().field, std::string("ARTIST"));
    CHECK_EQ(std_fields[7].label, std::string("Album Artist"));
    CHECK_EQ(std_fields[7].field, std::string("ALBUM ARTIST"));
    CHECK_EQ(std_fields.back().field, std::string("COMMENT"));
    auto custom = parse_standard_fields(" Who = artist ;bad;=X;Name=;Dup=ARTIST;Rating=rating");
    CHECK_EQ(custom.size(), size_t(3));
    CHECK_EQ(custom[0].label, std::string("Who"));
    CHECK_EQ(custom[0].field, std::string("ARTIST"));
    CHECK_EQ(custom[1].label, std::string("X"));
    CHECK_EQ(custom[2].field, std::string("RATING"));
    auto ml = parse_field_list(kDefaultMultiLineFields);
    CHECK_EQ(ml.size(), size_t(5));
    auto mv = parse_field_list(" artist ; ;Genre;ARTIST");
    CHECK_EQ(mv, (std::vector<std::string>{"ARTIST", "GENRE"}));
    Config c = Config::defaults();
    CHECK(c.isMultiValue("album artist"));
    CHECK(!c.isMultiValue("TITLE"));
    CHECK(c.isMultiLine("lyrics"));
}

TEST(standard_rows_first_then_sorted_others) {
    Table t = make({tf({{"title", {"Song"}}, {"zeta", {"z"}}, {"Alpha", {"a"}}, {"ARTIST", {"X", "Y"}}})});
    CHECK_EQ(t.size(), size_t(15));
    CHECK_EQ(t.row(0).label, std::string("Artist Name"));
    CHECK_EQ(t.row(0).field, std::string("ARTIST"));
    CHECK_EQ(t.row(1).label, std::string("Track Title"));
    CHECK_EQ(t.row(1).field, std::string("title"));
    CHECK(t.row(1).standard);
    CHECK_EQ(t.row(13).label, std::string("<ALPHA>"));
    CHECK_EQ(t.row(13).field, std::string("Alpha"));
    CHECK_EQ(t.row(14).label, std::string("<ZETA>"));
    CHECK(!t.row(14).standard);
    CHECK_EQ(t.display(0).text, std::string("X; Y"));
    CHECK(!t.display(0).mixed);
    CHECK_EQ(t.display(2).text, std::string(""));
    CHECK(!t.dirty());
}

TEST(merge_multiple_tracks_and_mixed_display) {
    Table t = make({
        tf({{"ARTIST", {"Beatles"}}, {"ALBUM", {"Abbey Road"}}, {"Genre", {"Rock", "Pop"}}, {"MOOD", {"calm"}}}),
        tf({{"artist", {"Beatles"}}, {"ALBUM", {"Help!"}}, {"GENRE", {"Rock", "Pop"}}}),
        tf({{"Artist", {"Beatles"}}, {"ALBUM", {"Abbey Road"}}, {"genre", {"Rock", "Pop"}}}),
    });
    CHECK_EQ(t.trackCount(), size_t(3));
    const size_t artist = idx(t, "ARTIST"), album = idx(t, "ALBUM"), genre = idx(t, "GENRE"), mood = idx(t, "MOOD");
    CHECK(artist != npos && album != npos && genre != npos && mood != npos);
    CHECK_EQ(t.row(artist).field, std::string("ARTIST"));
    CHECK_EQ(t.display(artist).text, std::string("Beatles"));
    CHECK(!t.display(artist).mixed);
    CHECK_EQ(t.display(album).text, kMV + "Abbey Road; Help!");
    CHECK(t.display(album).mixed);
    CHECK_EQ(t.editText(album), std::string("Abbey Road; Help!"));
    CHECK_EQ(t.display(genre).text, std::string("Rock; Pop"));
    CHECK_EQ(t.display(mood).text, kMV + "calm");
    CHECK(t.display(mood).mixed);
    CHECK_EQ(t.editText(mood), std::string("calm"));
}

TEST(unchanged_mixed_edit_keeps_per_track_values) {
    Table t = make({tf({{"ALBUM", {"A"}}}), tf({{"ALBUM", {"B"}}})});
    const size_t album = idx(t, "ALBUM");
    CHECK(!t.setText(album, t.editText(album)));
    CHECK(!t.dirty());
    CHECK(t.plan().empty());
    CHECK(t.changedTracks().empty());
    CHECK(t.setText(album, "C"));
    CHECK(t.dirty());
    CHECK_EQ(t.display(album).text, std::string("C"));
    CHECK_EQ(values_after(t, 0, "ALBUM"), Values{"C"});
    CHECK_EQ(values_after(t, 1, "ALBUM"), Values{"C"});
}

TEST(edits_on_other_rows_do_not_touch_mixed_rows) {
    Table t = make({tf({{"ALBUM", {"A"}}, {"DATE", {"1999"}}}), tf({{"ALBUM", {"B"}}, {"DATE", {"1999"}}})});
    CHECK(t.setText(idx(t, "DATE"), "2000"));
    auto plan = t.plan();
    CHECK_EQ(plan.ops.size(), size_t(1));
    CHECK_EQ(plan.ops[0].to, std::string("DATE"));
    CHECK_EQ(values_after(t, 0, "ALBUM"), Values{"A"});
    CHECK_EQ(values_after(t, 1, "ALBUM"), Values{"B"});
    CHECK_EQ(values_after(t, 1, "DATE"), Values{"2000"});
}

TEST(split_rule_multivalue_vs_single) {
    Table t = make({tf({{"MOOD", {"x", "y"}}})});
    CHECK(t.setText(idx(t, "ARTIST"), "A; B ;"));
    CHECK_EQ(t.row(idx(t, "ARTIST")).all, (Values{"A", "B"}));
    CHECK(t.setText(idx(t, "TITLE"), "Part 1; Part 2"));
    CHECK_EQ(t.row(idx(t, "TITLE")).all, Values{"Part 1; Part 2"});
    CHECK(t.usesMultiValue(idx(t, "MOOD")));
    CHECK(t.setText(idx(t, "MOOD"), "x; y; z"));
    CHECK_EQ(t.row(idx(t, "MOOD")).all, (Values{"x", "y", "z"}));
    CHECK(t.setText(idx(t, "TITLE"), "  "));
    CHECK(t.row(idx(t, "TITLE")).all.empty());
}

TEST(setting_original_values_back_is_not_dirty) {
    Table t = make({tf({{"TITLE", {"Song"}}})});
    const size_t title = idx(t, "TITLE");
    CHECK(t.setText(title, "Other"));
    CHECK(t.dirty());
    CHECK(t.setText(title, "Song"));
    CHECK(!t.dirty());
    CHECK(t.row(title).state == EditState::Untouched);
}

TEST(whitespace_only_value_removes_field) {
    Table t = make({tf({{"TITLE", {"Song"}}, {"MOOD", {"m"}}}), tf({{"TITLE", {"Other"}}})});
    CHECK(t.setText(idx(t, "TITLE"), " "));
    CHECK(!has_after(t, 0, "TITLE"));
    CHECK(!has_after(t, 1, "TITLE"));
    CHECK(has_after(t, 0, "MOOD"));
    CHECK_EQ(t.changedTracks(), (std::vector<size_t>{0, 1}));
}

TEST(rename_moves_values_per_track) {
    Table t = make({tf({{"MOOD", {"calm"}}}), tf({{"MOOD", {"angry", "loud"}}}), tf({{"TITLE", {"x"}}})});
    const size_t mood = idx(t, "MOOD");
    CHECK(t.rename(mood, " feeling ") == NameResult::Ok);
    CHECK_EQ(t.row(mood).field, std::string("FEELING"));
    CHECK_EQ(t.row(mood).label, std::string("<FEELING>"));
    auto plan = t.plan();
    CHECK_EQ(plan.ops.size(), size_t(1));
    CHECK(plan.ops[0].kind == Op::Move);
    CHECK(!plan.ops[0].explicitValues);
    CHECK_EQ(values_after(t, 0, "FEELING"), Values{"calm"});
    CHECK_EQ(values_after(t, 1, "FEELING"), (Values{"angry", "loud"}));
    CHECK(!has_after(t, 1, "MOOD"));
    CHECK(!has_after(t, 2, "FEELING"));
    CHECK_EQ(t.changedTracks(), (std::vector<size_t>{0, 1}));
}

TEST(rename_rules) {
    Table t = make({tf({{"MOOD", {"calm"}}, {"TEMPO", {"slow"}}})});
    size_t existing = npos;
    CHECK(t.rename(idx(t, "ARTIST"), "PERFORMER") == NameResult::NotAllowed);
    CHECK(t.rename(idx(t, "MOOD"), "tempo", &existing) == NameResult::Duplicate);
    CHECK_EQ(existing, idx(t, "TEMPO"));
    CHECK(t.rename(idx(t, "MOOD"), "artist", &existing) == NameResult::Duplicate);
    CHECK(t.rename(idx(t, "MOOD"), "A=B") == NameResult::Invalid);
    CHECK(t.rename(idx(t, "MOOD"), "   ") == NameResult::Invalid);
    CHECK(t.rename(idx(t, "MOOD"), "MOOD") == NameResult::Unchanged);
    CHECK(!t.dirty());
}

TEST(rename_with_value_edit_is_explicit) {
    Table t = make({tf({{"MOOD", {"a"}}}), tf({{"MOOD", {"b"}}})});
    const size_t mood = idx(t, "MOOD");
    CHECK(t.rename(mood, "FEELING") == NameResult::Ok);
    CHECK(t.setText(mood, "same"));
    auto plan = t.plan();
    CHECK_EQ(plan.ops.size(), size_t(1));
    CHECK(plan.ops[0].explicitValues);
    CHECK_EQ(values_after(t, 0, "FEELING"), Values{"same"});
    CHECK_EQ(values_after(t, 1, "FEELING"), Values{"same"});
    CHECK(!has_after(t, 0, "MOOD"));
}

TEST(swap_two_field_names) {
    Table t = make({tf({{"AAA", {"1"}}, {"BBB", {"2"}}})});
    const size_t a = idx(t, "AAA"), b = idx(t, "BBB");
    CHECK(t.rename(a, "CCC") == NameResult::Ok);
    CHECK(t.rename(b, "AAA") == NameResult::Ok);
    CHECK(t.rename(a, "BBB") == NameResult::Ok);
    CHECK_EQ(values_after(t, 0, "AAA"), Values{"2"});
    CHECK_EQ(values_after(t, 0, "BBB"), Values{"1"});
    CHECK(!has_after(t, 0, "CCC"));
}

TEST(case_only_rename) {
    Table t = make({tf({{"Mood", {"x"}}})});
    const size_t m = idx(t, "MOOD");
    CHECK(t.rename(m, "mood") == NameResult::Ok);
    CHECK(t.row(m).renamed());
    MemoryStore s(t.loadedFields(0));
    CHECK(apply(t.plan(), 0, s));
    CHECK_EQ(s.fields.size(), size_t(1));
    CHECK_EQ(s.fields[0].name, std::string("MOOD"));
    CHECK_EQ(s.fields[0].values, Values{"x"});
}

TEST(add_new_field_flow) {
    Table t = make({tf({{"TITLE", {"x"}}}), tf({{"TITLE", {"y"}}})});
    const size_t before = t.size();
    const size_t r = t.addRow();
    CHECK_EQ(r, before);
    CHECK(t.isPendingName(r));
    CHECK(!t.dirty());
    size_t at = npos;
    CHECK(t.nameNewRow(r, " rating ", &at) == NameResult::Ok);
    CHECK_EQ(at, r);
    CHECK_EQ(t.row(r).field, std::string("RATING"));
    CHECK(!t.dirty());
    CHECK(t.plan().empty());
    CHECK(t.setText(r, "5"));
    CHECK(t.dirty());
    CHECK_EQ(values_after(t, 0, "RATING"), Values{"5"});
    CHECK_EQ(values_after(t, 1, "RATING"), Values{"5"});
}

TEST(add_new_field_duplicate_or_invalid) {
    Table t = make({tf({{"MOOD", {"x"}}})});
    const size_t n = t.size();
    size_t r = t.addRow(), at = npos;
    CHECK(t.nameNewRow(r, "mood", &at) == NameResult::Duplicate);
    CHECK_EQ(at, idx(t, "MOOD"));
    CHECK_EQ(t.size(), n);
    r = t.addRow();
    CHECK(t.nameNewRow(r, "", &at) == NameResult::Invalid);
    CHECK_EQ(at, npos);
    CHECK_EQ(t.size(), n);
    r = t.addRow();
    t.discardPendingRow(r);
    CHECK_EQ(t.size(), n);
    CHECK(!t.dirty());
}

TEST(remove_rows) {
    Table t = make({tf({{"ARTIST", {"A"}}, {"MOOD", {"m"}}, {"TEMPO", {"t"}}})});
    const size_t n = t.size();
    const size_t extra = t.addRow();
    size_t at = npos;
    CHECK(t.nameNewRow(extra, "NEWONE", &at) == NameResult::Ok);
    CHECK_EQ(t.remove({idx(t, "ARTIST"), idx(t, "MOOD"), idx(t, "NEWONE")}), size_t(3));
    CHECK_EQ(t.size(), n - 1);
    CHECK(idx(t, "ARTIST") != npos);
    CHECK_EQ(t.display(idx(t, "ARTIST")).text, std::string(""));
    CHECK_EQ(idx(t, "MOOD"), npos);
    CHECK(t.dirty());
    auto plan = t.plan();
    CHECK_EQ(plan.ops.size(), size_t(2));
    CHECK(plan.ops[0].kind == Op::Remove);
    CHECK_EQ(plan.ops[0].from, std::string("MOOD"));
    CHECK(!has_after(t, 0, "ARTIST"));
    CHECK(!has_after(t, 0, "MOOD"));
    CHECK(has_after(t, 0, "TEMPO"));
}

TEST(clearing_empty_standard_row_is_noop) {
    Table t = make({tf({{"TITLE", {"x"}}})});
    CHECK_EQ(t.remove({idx(t, "COMPOSER")}), size_t(0));
    CHECK(!t.dirty());
}

TEST(remove_then_readd_and_rename_into_removed_name) {
    Table t = make({tf({{"MOOD", {"old"}}, {"VIBE", {"v"}}})});
    t.remove({idx(t, "MOOD")});
    CHECK(t.rename(idx(t, "VIBE"), "MOOD") == NameResult::Ok);
    CHECK_EQ(values_after(t, 0, "MOOD"), Values{"v"});
    CHECK(!has_after(t, 0, "VIBE"));

    Table u = make({tf({{"MOOD", {"old"}}})});
    u.remove({idx(u, "MOOD")});
    size_t r = u.addRow(), at = npos;
    CHECK(u.nameNewRow(r, "MOOD", &at) == NameResult::Ok);
    CHECK(u.setText(at, "new"));
    CHECK_EQ(values_after(u, 0, "MOOD"), Values{"new"});
}

TEST(capitalize_keeps_per_track_differences) {
    Table t = make({tf({{"TITLE", {"hello world"}}}), tf({{"TITLE", {"good bye"}}}), tf({{"TITLE", {"Done"}}})});
    const size_t title = idx(t, "TITLE");
    CHECK_EQ(t.capitalize({title}, capitalize_ascii), size_t(1));
    CHECK(t.row(title).state == EditState::SetPerTrack);
    CHECK_EQ(values_after(t, 0, "TITLE"), Values{"Hello World"});
    CHECK_EQ(values_after(t, 1, "TITLE"), Values{"Good Bye"});
    CHECK_EQ(values_after(t, 2, "TITLE"), Values{"Done"});
    CHECK_EQ(t.changedTracks(), (std::vector<size_t>{0, 1}));
    CHECK_EQ(t.capitalize({idx(t, "ARTIST")}, capitalize_ascii), size_t(0));
}

TEST(auto_track_number) {
    Table t = make({tf({{"TRACKNUMBER", {"7"}}}), tf({}), tf({{"TRACKNUMBER", {"2"}}})});
    CHECK(t.autoTrackNumber());
    CHECK_EQ(values_after(t, 0, "TRACKNUMBER"), Values{"1"});
    CHECK_EQ(values_after(t, 1, "TRACKNUMBER"), Values{"2"});
    CHECK_EQ(values_after(t, 2, "TRACKNUMBER"), Values{"3"});
    CHECK_EQ(values_after(t, 2, "TOTALTRACKS"), Values{"3"});
    CHECK_EQ(t.display(idx(t, "TRACKNUMBER")).text, kMV + "1; 2; 3");

    Table u;
    u.load({tf({}), tf({})}, Config::parse("Title=TITLE", "", ""));
    CHECK(u.autoTrackNumber());
    CHECK(idx(u, "TRACKNUMBER") != npos);
    CHECK_EQ(u.row(idx(u, "TOTALTRACKS")).label, std::string("<TOTALTRACKS>"));
}

TEST(copy_and_paste) {
    Table t = make({tf({{"ARTIST", {"A", "B"}}, {"ALBUM", {"X"}}}), tf({{"ARTIST", {"A", "B"}}, {"ALBUM", {"Y"}}})});
    const std::string copied = t.copyText({idx(t, "ARTIST"), idx(t, "ALBUM")});
    CHECK_EQ(copied, std::string("ARTIST=A; B\nALBUM=") + kMV + "X; Y");

    Table u = make({tf({{"TITLE", {"t"}}})});
    std::vector<size_t> touched;
    CHECK(u.paste("artist=A; B\r\nMOOD=calm\nLYRICS=line1\nline2\n", {}, &touched));
    CHECK_EQ(u.row(idx(u, "ARTIST")).all, (Values{"A", "B"}));
    CHECK(idx(u, "MOOD") != npos);
    CHECK_EQ(u.row(idx(u, "MOOD")).all, Values{"calm"});
    CHECK_EQ(u.row(idx(u, "LYRICS")).all, Values{"line1\nline2\n"});
    CHECK_EQ(touched.size(), size_t(3));

    Table v = make({tf({{"TITLE", {"t"}}})});
    CHECK(v.paste("plain text\n", {idx(v, "TITLE")}));
    CHECK_EQ(v.row(idx(v, "TITLE")).all, Values{"plain text"});
    CHECK(!v.paste("no target", {}));
    CHECK(!v.paste("no target", {0, 1}));
}

TEST(editing_a_mixed_multi_value_row_never_duplicates_values) {
    Table t = make({tf({{"ARTIST", {"A", "B"}}}), tf({{"ARTIST", {"A"}}})});
    const size_t artist = idx(t, "ARTIST");
    CHECK_EQ(t.editText(artist), std::string("A; B"));
    CHECK_EQ(t.display(artist).text, kMV + "A; B");
    CHECK(!t.setText(artist, t.editText(artist)));
    CHECK(t.setText(artist, t.editText(artist) + "; C"));
    CHECK_EQ(values_after(t, 0, "ARTIST"), (Values{"A", "B", "C"}));
    CHECK_EQ(values_after(t, 1, "ARTIST"), (Values{"A", "B", "C"}));

    Table u = make({tf({{"GENRE", {"Rock", "Pop"}}}), tf({{"GENRE", {"Pop", "Rock"}}})});
    const size_t genre = idx(u, "GENRE");
    CHECK_EQ(u.editText(genre), std::string("Rock; Pop"));
    CHECK(u.setText(genre, "Rock; Pop; Jazz"));
    CHECK_EQ(values_after(u, 1, "GENRE"), (Values{"Rock", "Pop", "Jazz"}));
}

TEST(copied_mixed_rows_are_marked_and_not_pasted) {
    Table src = make({tf({{"TITLE", {"Song A"}}, {"ALBUM", {"X"}}}), tf({{"TITLE", {"Song B"}}, {"ALBUM", {"X"}}})});
    const std::string copied = src.copyText({idx(src, "TITLE"), idx(src, "ALBUM")});
    CHECK_EQ(copied, std::string("TITLE=") + kMV + "Song A; Song B\nALBUM=X");

    Table dst = make({tf({{"TITLE", {"One"}}, {"ALBUM", {"Old"}}}), tf({{"TITLE", {"Two"}}, {"ALBUM", {"Old"}}})});
    std::vector<size_t> touched;
    CHECK(dst.paste(copied, {}, &touched));
    CHECK_EQ(touched, std::vector<size_t>{idx(dst, "ALBUM")});
    CHECK_EQ(values_after(dst, 0, "TITLE"), Values{"One"});
    CHECK_EQ(values_after(dst, 1, "TITLE"), Values{"Two"});
    CHECK_EQ(values_after(dst, 1, "ALBUM"), Values{"X"});

    CHECK(!src.paste(copied, {}));
    CHECK_EQ(values_after(src, 0, "TITLE"), Values{"Song A"});
    CHECK(!src.dirty());
}

TEST(multi_line_values_with_equals_signs_round_trip) {
    Table src = make({tf({{"COMMENT", {"Ripped with EAC\nlog=ok"}}, {"LYRICS", {"Verse\nChorus = x\n\tindented"}}})});
    const std::string copied = src.copyText({idx(src, "COMMENT"), idx(src, "LYRICS")});
    CHECK_EQ(copied, std::string("COMMENT=Ripped with EAC\n\tlog=ok\nLYRICS=Verse\n\tChorus = x\n\t\tindented"));

    Table dst = make({tf({{"TITLE", {"t"}}})});
    const size_t rows = dst.size();
    CHECK(dst.paste(copied, {}));
    CHECK_EQ(dst.size(), rows + 1);
    CHECK_EQ(idx(dst, "LOG"), npos);
    CHECK_EQ(idx(dst, "CHORUS"), npos);
    CHECK_EQ(values_after(dst, 0, "COMMENT"), Values{"Ripped with EAC\nlog=ok"});
    CHECK_EQ(values_after(dst, 0, "LYRICS"), Values{"Verse\nChorus = x\n\tindented"});
}

TEST(plain_text_with_equals_signs_pastes_into_the_selected_row) {
    Table t = make({tf({{"TITLE", {"t"}}})});
    const size_t rows = t.size(), comment = idx(t, "COMMENT");
    CHECK(t.paste("https://example.com/watch?v=abc", {comment}));
    CHECK_EQ(t.size(), rows);
    CHECK_EQ(values_after(t, 0, "COMMENT"), Values{"https://example.com/watch?v=abc"});
    CHECK(!t.paste("https://example.com/watch?v=abc", {}));
    CHECK_EQ(t.size(), rows);

    Table u = make({tf({{"TITLE", {"t"}}})});
    CHECK(u.paste("Verse one\nChorus = x", {idx(u, "COMMENT")}));
    CHECK_EQ(idx(u, "CHORUS"), npos);
    CHECK_EQ(values_after(u, 0, "COMMENT"), Values{"Verse one\nChorus = x"});
    CHECK(u.paste("ALBUM ARTIST=Various\nMY_TAG (2)=v", {}));
    CHECK_EQ(values_after(u, 0, "ALBUM ARTIST"), Values{"Various"});
    CHECK_EQ(values_after(u, 0, "MY_TAG (2)"), Values{"v"});
}

TEST(changed_tracks_skips_tracks_already_matching) {
    Table t = make({tf({{"ALBUM", {"Same"}}}), tf({{"ALBUM", {"Other"}}}), tf({{"ALBUM", {"Same"}}})});
    CHECK(t.setText(idx(t, "ALBUM"), "Same"));
    CHECK_EQ(t.changedTracks(), (std::vector<size_t>{1}));
}

TEST(apply_is_idempotent) {
    Table t = make({tf({{"MOOD", {"m"}}, {"OLD", {"o"}}, {"TITLE", {"t"}}}), tf({{"TITLE", {"u"}}})});
    t.rename(idx(t, "MOOD"), "FEEL");
    t.remove({idx(t, "OLD")});
    t.setText(idx(t, "TITLE"), "new");
    t.capitalize({idx(t, "FEEL")}, capitalize_ascii);
    const Plan p = t.plan();
    for (size_t track = 0; track < 2; ++track) {
        MemoryStore s(t.loadedFields(track));
        CHECK(apply(p, track, s));
        const TrackFields first = s.fields;
        CHECK(!apply(p, track, s));
        CHECK_EQ(s.fields.size(), first.size());
    }
    MemoryStore s0(t.loadedFields(0));
    apply(p, 0, s0);
    CHECK_EQ(s0.get("FEEL"), Values{"M"});
    CHECK(!s0.has("MOOD"));
    CHECK(!s0.has("OLD"));
}

TEST(multiline_detection) {
    Table t = make({tf({{"NOTES", {"a\nb"}}, {"MOOD", {"x"}}})});
    CHECK(t.isMultiline(idx(t, "COMMENT")));
    CHECK(t.isMultiline(idx(t, "NOTES")));
    CHECK(!t.isMultiline(idx(t, "MOOD")));
    CHECK_EQ(t.display(idx(t, "NOTES")).text, std::string("a \xE2\x86\xB5 b"));
    CHECK_EQ(t.editText(idx(t, "NOTES")), std::string("a\nb"));
    CHECK(t.setText(idx(t, "COMMENT"), "line one\nline two"));
    CHECK_EQ(t.row(idx(t, "COMMENT")).all, Values{"line one\nline two"});
}

TEST(memory_store_case_insensitive) {
    MemoryStore s({{"Artist", {"a"}}});
    CHECK(s.has("ARTIST"));
    s.add("ARTIST", "b");
    CHECK_EQ(s.get("artist"), (Values{"a", "b"}));
    s.remove("aRtIsT");
    CHECK(!s.has("Artist"));
}

TEST(empty_selection_table) {
    Table t;
    t.load({}, Config::defaults());
    CHECK_EQ(t.display(0).text, std::string(""));
    CHECK(!t.setText(0, "x"));
    CHECK(t.changedTracks().empty());
}

TEST(changed_fields_lists_every_touched_name_once) {
    Table t = make({tf({{"MOOD", {"m"}}, {"Old", {"o"}}, {"TITLE", {"t"}}, {"ALBUM", {"A"}}}),
                    tf({{"TITLE", {"u"}}, {"ALBUM", {"B"}}})});
    CHECK(t.changedFields().empty());
    CHECK(!t.setText(idx(t, "ALBUM"), t.editText(idx(t, "ALBUM"))));
    CHECK(t.changedFields().empty());
    CHECK(t.rename(idx(t, "MOOD"), "feel") == NameResult::Ok);
    t.remove({idx(t, "OLD")});
    CHECK(t.setText(idx(t, "TITLE"), "x"));
    CHECK(t.setText(idx(t, "COMPOSER"), "c"));
    CHECK_EQ(t.changedFields(), (std::vector<std::string>{"OLD", "TITLE", "COMPOSER", "MOOD", "FEEL"}));
    Table u = make({tf({{"Mood", {"x"}}})});
    CHECK(u.rename(idx(u, "MOOD"), "MOOD") == NameResult::Ok);
    CHECK_EQ(u.changedFields(), std::vector<std::string>{"MOOD"});
}

TEST(per_track_plan_mixes_set_all_and_untouched_rows) {
    Table t = make({tf({{"ARTIST", {"A"}}, {"ALBUM", {"X"}}, {"DATE", {"1990"}}}),
                    tf({{"ARTIST", {"B"}}, {"ALBUM", {"Y"}}}),
                    tf({{"ARTIST", {"A"}}, {"ALBUM", {"X"}}, {"DATE", {"1991"}}})});
    CHECK(t.setText(idx(t, "ARTIST"), "Same; Other"));
    CHECK(t.autoTrackNumber());
    const Plan p = t.plan();
    CHECK_EQ(p.ops.size(), size_t(3));
    for (size_t track = 0; track < 3; ++track) {
        CHECK_EQ(values_after(t, track, "ARTIST"), (Values{"Same", "Other"}));
        CHECK_EQ(values_after(t, track, "TRACKNUMBER"), Values{std::to_string(track + 1)});
        CHECK_EQ(values_after(t, track, "TOTALTRACKS"), Values{"3"});
    }
    CHECK_EQ(values_after(t, 0, "ALBUM"), Values{"X"});
    CHECK_EQ(values_after(t, 1, "ALBUM"), Values{"Y"});
    CHECK_EQ(values_after(t, 0, "DATE"), Values{"1990"});
    CHECK(!has_after(t, 1, "DATE"));
    CHECK_EQ(values_after(t, 2, "DATE"), Values{"1991"});
    CHECK_EQ(t.changedTracks(), (std::vector<size_t>{0, 1, 2}));
}

TEST(tools_remove_all_fields_clears_standard_rows_and_removes_others) {
    Table t = make({tf({{"ARTIST", {"A"}}, {"MOOD", {"calm"}}, {"RATING", {"5"}}}), tf({{"MOOD", {"angry"}}})});
    const size_t standard = Config::defaults().standard.size();
    CHECK_EQ(t.fieldRows().size(), standard + 2);
    CHECK(t.removeAll() > 0);
    CHECK_EQ(t.size(), standard);  // standard rows stay, cleared
    for (size_t track = 0; track < 2; ++track) {
        CHECK(!has_after(t, track, "ARTIST"));
        CHECK(!has_after(t, track, "MOOD"));
        CHECK(!has_after(t, track, "RATING"));
    }
    CHECK_EQ(t.changedTracks(), (std::vector<size_t>{0, 1}));
    CHECK(t.currentFields(0).empty());

    // A new row still being named is not a field.
    Table u = make({tf({{"TITLE", {"t"}}})});
    const size_t pending = u.addRow();
    const auto rows = u.fieldRows();
    CHECK(std::find(rows.begin(), rows.end(), pending) == rows.end());
}

TEST(tools_copy_all_then_paste_fields_round_trips) {
    Table t = make({tf({{"ARTIST", {"A", "B"}}, {"MOOD", {"calm"}}, {"COMMENT", {"line1\nline2"}}})});
    const std::string all = t.copyText(t.valueRows());
    CHECK_EQ(all, std::string("ARTIST=A; B\nCOMMENT=line1\n\tline2\nMOOD=calm"));
    Table u = make({tf({{"TITLE", {"keep"}}})});
    std::vector<size_t> touched;
    CHECK(u.paste(all, {}, &touched));
    CHECK_EQ(values_after(u, 0, "ARTIST"), (Values{"A", "B"}));
    CHECK_EQ(values_after(u, 0, "MOOD"), Values{"calm"});
    CHECK_EQ(values_after(u, 0, "COMMENT"), Values{"line1\nline2"});
    CHECK_EQ(values_after(u, 0, "TITLE"), Values{"keep"});
    // "Paste fields" never pastes plain text into a row.
    CHECK(!u.paste("plain text", {}));
}

TEST(tools_format_sets_one_value_per_track) {
    Table t = make({tf({{"ARTIST", {"A"}}, {"TITLE", {"x"}}}), tf({{"ARTIST", {"B"}}, {"TITLE", {"y"}}})});
    size_t row = npos;
    CHECK(t.setFormatted("title", {"A - x", "B - y"}, &row));
    CHECK_EQ(row, idx(t, "TITLE"));
    CHECK_EQ(values_after(t, 0, "TITLE"), Values{"A - x"});
    CHECK_EQ(values_after(t, 1, "TITLE"), Values{"B - y"});
    CHECK(!t.setFormatted("TITLE", {"A - x", "B - y"}));  // already so

    // New fields are added; multi-value fields split on ';' like typed text; empty results remove.
    CHECK(t.setFormatted("Genre", {"Rock; Pop", ""}, &row));
    CHECK_EQ(values_after(t, 0, "GENRE"), (Values{"Rock", "Pop"}));
    CHECK(!has_after(t, 1, "GENRE"));
    CHECK(t.setFormatted("SORTKEY", {"a", "b"}, &row));
    CHECK_EQ(t.row(row).label, std::string("<SORTKEY>"));

    CHECK(!t.setFormatted("BAD=NAME", {"a", "b"}));
    CHECK(!t.setFormatted("TITLE", {"only one"}));

    // The staged state is what later formatting sees.
    const TrackFields now = t.currentFields(1);
    MemoryStore s(now);
    CHECK_EQ(s.get("TITLE"), Values{"B - y"});
    CHECK_EQ(s.get("SORTKEY"), Values{"b"});
}

// The "Edit Value" sheet's model: one text per track, merged back as per-track values.
TEST(per_track_edit_texts_follow_the_list) {
    Table t = make({tf({{"ARTIST", {"A", "B"}}, {"MOOD", {"calm"}}}), tf({{"ARTIST", {"C"}}}), tf({{"TITLE", {"x"}}})});
    PerTrackEdit e(t, idx(t, "ARTIST"));
    CHECK_EQ(e.field(), std::string("ARTIST"));
    CHECK_EQ(e.label(), std::string("Artist Name"));  // as the Name column shows it
    CHECK_EQ(e.size(), size_t(3));
    CHECK(e.multiValue());
    CHECK_EQ(e.text(0), std::string("A; B"));
    CHECK_EQ(e.text(1), std::string("C"));
    CHECK_EQ(e.text(2), std::string(""));  // absent
    CHECK(!e.dirty());
    CHECK(!e.allSame());
    CHECK_EQ(e.commonText(), std::string(kDifferentValues));

    PerTrackEdit m(t, idx(t, "MOOD"));
    CHECK_EQ(m.label(), std::string("<MOOD>"));
    CHECK(!m.multiValue());
    CHECK(!m.multiline(0));
    PerTrackEdit c(t, idx(t, "COMMENT"));
    CHECK(c.multiline(0));
    CHECK(c.allSame());
    CHECK_EQ(c.commonText(), std::string(""));

    // Staged values are what the sheet starts from.
    CHECK(t.setText(idx(t, "MOOD"), "happy"));
    PerTrackEdit staged(t, idx(t, "MOOD"));
    CHECK(staged.allSame());
    CHECK_EQ(staged.commonText(), std::string("happy"));
}

TEST(per_track_edit_change_detection) {
    Table t = make({tf({{"MOOD", {"a"}}}), tf({{"MOOD", {"b"}}}), tf({})});
    PerTrackEdit e(t, idx(t, "MOOD"));
    CHECK(!e.setText(0, "a"));
    CHECK(e.setText(1, "z"));
    CHECK(!e.setText(1, "z"));
    CHECK(!e.setText(7, "out of range"));
    CHECK(e.changed(1));
    CHECK(!e.changed(0));
    CHECK_EQ(e.changedTracks(), (std::vector<size_t>{1}));
    CHECK(e.dirty());
    CHECK(e.setText(1, "b"));  // typed back: unchanged again
    CHECK(!e.dirty());
    CHECK(e.setText(1, "b\nc"));
    CHECK(e.multiline(1));
    CHECK(!e.multiline(0));
}

TEST(per_track_edit_merges_into_the_table_per_track) {
    Table t = make({tf({{"ARTIST", {"A"}}, {"TITLE", {"1"}}}), tf({{"ARTIST", {"B"}}, {"TITLE", {"2"}}}),
                    tf({{"ARTIST", {"C"}}, {"TITLE", {"3"}}})});
    const size_t artist = idx(t, "ARTIST");
    PerTrackEdit e(t, artist);
    CHECK(e.setText(1, "X; Y"));  // multi-value field: split per track
    CHECK(e.setText(2, "  "));    // cleared: removes the field on that track only
    size_t row = npos;
    CHECK(e.apply(t, &row));
    CHECK_EQ(row, artist);
    CHECK(t.dirty());
    CHECK(t.row(artist).state == EditState::SetPerTrack);
    CHECK_EQ(t.display(artist).text, kMV + "A; X; Y");
    CHECK_EQ(values_after(t, 0, "ARTIST"), Values{"A"});
    CHECK_EQ(values_after(t, 1, "ARTIST"), (Values{"X", "Y"}));
    CHECK(!has_after(t, 2, "ARTIST"));
    CHECK_EQ(values_after(t, 2, "TITLE"), Values{"3"});
    // Only the tracks whose value changed are written, and only that field.
    CHECK_EQ(t.changedTracks(), (std::vector<size_t>{1, 2}));
    CHECK_EQ(t.changedFields(), std::vector<std::string>{"ARTIST"});

    // Editing again starts from the staged values; making every track equal shows one value.
    PerTrackEdit again(t, artist);
    CHECK_EQ(again.text(1), std::string("X; Y"));
    CHECK_EQ(again.text(2), std::string(""));
    CHECK(again.setCommon("Same"));
    CHECK(again.apply(t));
    CHECK_EQ(t.display(artist).text, std::string("Same"));
    CHECK(!t.display(artist).mixed);
    CHECK_EQ(t.changedTracks(), (std::vector<size_t>{0, 1, 2}));

    // Back to what the files have: nothing is staged any more.
    PerTrackEdit undo(t, artist);
    CHECK(undo.setText(0, "A"));
    CHECK(undo.setText(1, "B"));
    CHECK(undo.setText(2, "C"));
    CHECK(undo.apply(t));
    CHECK(t.row(artist).state == EditState::Untouched);
    CHECK(!t.dirty());
}

TEST(per_track_edit_keeps_untouched_tracks_exactly) {
    // Text that would not survive a re-parse (a ';' in a single-value field is literal, spaces around
    // multi-value parts are trimmed): untouched tracks keep their values as they are.
    Table t = make({tf({{"GENRE", {" Rock ", "Pop"}}, {"MOOD", {"a;b"}}}), tf({{"GENRE", {"Jazz"}}, {"MOOD", {"c"}}})});
    PerTrackEdit g(t, idx(t, "GENRE"));
    CHECK(g.setText(1, "Funk;Soul"));
    CHECK_EQ(g.values(), (std::vector<Values>{{" Rock ", "Pop"}, {"Funk", "Soul"}}));
    CHECK(g.apply(t));
    CHECK_EQ(t.changedTracks(), std::vector<size_t>{1});
    CHECK_EQ(values_after(t, 0, "GENRE"), (Values{" Rock ", "Pop"}));

    PerTrackEdit m(t, idx(t, "MOOD"));
    CHECK(!m.multiValue());
    CHECK(m.setText(1, "d;e"));  // not a multi-value field: ';' stays literal
    CHECK_EQ(m.values(), (std::vector<Values>{{"a;b"}, {"d;e"}}));
    CHECK(m.apply(t));
    CHECK_EQ(values_after(t, 1, "MOOD"), Values{"d;e"});
    CHECK_EQ(values_after(t, 0, "MOOD"), Values{"a;b"});
}

TEST(per_track_edit_keeps_staged_set_all_values_and_renames) {
    Table t = make({tf({{"MOOD", {"a"}}}), tf({{"MOOD", {"b"}}}), tf({{"MOOD", {"c"}}})});
    const size_t mood = idx(t, "MOOD");
    CHECK(t.setText(mood, "all"));
    CHECK(t.rename(mood, "feel") == NameResult::Ok);
    PerTrackEdit e(t, mood);
    CHECK_EQ(e.field(), std::string("FEEL"));
    CHECK_EQ(e.text(0), std::string("all"));
    CHECK(e.setText(2, "own"));
    CHECK(e.apply(t));
    CHECK_EQ(values_after(t, 0, "FEEL"), Values{"all"});
    CHECK_EQ(values_after(t, 2, "FEEL"), Values{"own"});
    CHECK(!has_after(t, 1, "MOOD"));
    CHECK_EQ(t.plan().ops.size(), size_t(1));
    CHECK(t.plan().ops[0].kind == Op::Move);
    CHECK(t.plan().ops[0].perTrack);
}

TEST(per_track_plan_keeps_unchanged_tracks_as_the_file_has_them) {
    // Tracks whose staged value is still the loaded one are marked keep: when the tags are written for
    // another reason, the field is left as the file has it then, never reset to the snapshot.
    Table t = make({tf({{"ARTIST", {"A"}}, {"TITLE", {"1"}}}), tf({{"ARTIST", {"B"}}, {"TITLE", {"2"}}}),
                    tf({{"ARTIST", {"C"}}, {"TITLE", {"3"}}})});
    CHECK(t.setText(idx(t, "TITLE"), "Same"));  // every track will be written
    PerTrackEdit e(t, idx(t, "ARTIST"));
    CHECK(e.setText(1, "X"));
    CHECK(e.apply(t));
    const Plan p = t.plan();
    const Op* artist = nullptr;
    for (auto& op : p.ops)
        if (op.to == "ARTIST") artist = &op;
    CHECK(artist != nullptr);
    if (!artist) return;
    CHECK(artist->perTrack);
    CHECK(artist->keep == (std::vector<bool>{true, false, true}));
    CHECK(artist->keeps(0));
    CHECK(!artist->keeps(1));
    CHECK_EQ(t.changedTracks(), (std::vector<size_t>{0, 1, 2}));

    // Track 2's ARTIST was changed elsewhere after loading: it survives, TITLE is still written.
    MemoryStore stale(tf({{"ARTIST", {"C Band"}}, {"TITLE", {"3"}}}));
    CHECK(apply(p, 2, stale));
    CHECK_EQ(stale.get("ARTIST"), Values{"C Band"});
    CHECK_EQ(stale.get("TITLE"), Values{"Same"});
    MemoryStore changed(tf({{"ARTIST", {"B Band"}}, {"TITLE", {"2"}}}));
    CHECK(apply(p, 1, changed));
    CHECK_EQ(changed.get("ARTIST"), Values{"X"});  // the track the user edited gets the edit

    // A kept track that gained the field elsewhere keeps it too (nothing to remove).
    MemoryStore gained(tf({{"TITLE", {"1"}}, {"ARTIST", {"A"}}, {"MOOD", {"m"}}}));
    CHECK(apply(p, 0, gained));
    CHECK_EQ(gained.get("ARTIST"), Values{"A"});
    CHECK_EQ(gained.get("MOOD"), Values{"m"});

    // Other per-track stagings (Capitalize here) leave tracks they did not change alone as well.
    Table c = make({tf({{"MOOD", {"Calm"}}}), tf({{"MOOD", {"tense"}}})});
    CHECK_EQ(c.capitalize({idx(c, "MOOD")}, [](const std::string& v) {
        std::string o = v;
        if (!o.empty()) o[0] = static_cast<char>(std::toupper(static_cast<unsigned char>(o[0])));
        return o;
    }), size_t(1));
    CHECK(c.plan().ops[0].keep == (std::vector<bool>{true, false}));
    MemoryStore calm(tf({{"MOOD", {"calm, then angry"}}}));
    CHECK(!apply(c.plan(), 0, calm));
    CHECK_EQ(calm.get("MOOD"), Values{"calm, then angry"});
}

TEST(per_track_rename_moves_kept_tracks_as_they_are) {
    Table t = make({tf({{"MOOD", {"a"}}}), tf({{"MOOD", {"b"}}}), tf({{"TITLE", {"t"}}})});
    const size_t mood = idx(t, "MOOD");
    CHECK(t.rename(mood, "FEEL") == NameResult::Ok);
    PerTrackEdit e(t, mood);
    CHECK(e.setText(1, "own"));
    CHECK(e.apply(t));
    const Plan p = t.plan();
    CHECK_EQ(p.ops.size(), size_t(1));
    CHECK(p.ops[0].kind == Op::Move);
    CHECK(p.ops[0].explicitValues);
    CHECK(p.ops[0].keep == (std::vector<bool>{true, false, true}));
    // Kept: the value the file has at write time is moved, not the snapshot.
    MemoryStore s0(tf({{"MOOD", {"a2"}}}));
    CHECK(apply(p, 0, s0));
    CHECK(!s0.has("MOOD"));
    CHECK_EQ(s0.get("FEEL"), Values{"a2"});
    MemoryStore s1(tf({{"MOOD", {"b2"}}}));
    CHECK(apply(p, 1, s1));
    CHECK_EQ(s1.get("FEEL"), Values{"own"});
    MemoryStore s2(tf({{"TITLE", {"t"}}}));
    CHECK(!apply(p, 2, s2));  // no MOOD there: nothing to move or add
    CHECK(!s2.has("FEEL"));
    CHECK_EQ(values_after(t, 0, "FEEL"), Values{"a"});
    CHECK_EQ(t.changedTracks(), (std::vector<size_t>{0, 1}));
}

TEST(per_track_edit_common_value_like_the_host) {
    Table t = make({tf({{"DATE", {"1999"}}}), tf({{"DATE", {"2001"}}})});
    PerTrackEdit e(t, idx(t, "DATE"));
    CHECK_EQ(e.commonText(), std::string(kDifferentValues));
    CHECK(!e.setCommon(kDifferentValues));  // left as it is: every track keeps its own value
    CHECK(!e.dirty());
    CHECK(e.setCommon("2024"));
    CHECK(e.allSame());
    CHECK_EQ(e.commonText(), std::string("2024"));
    CHECK(e.setCommon(""));  // an empty common value clears the field everywhere
    CHECK(e.apply(t));
    CHECK(!has_after(t, 0, "DATE"));
    CHECK(!has_after(t, 1, "DATE"));
}

TEST(per_track_edit_without_changes_or_row_stages_nothing) {
    Table t = make({tf({{"MOOD", {"a"}}}), tf({{"MOOD", {"b"}}})});
    PerTrackEdit e(t, idx(t, "MOOD"));
    size_t row = npos;
    CHECK(!e.apply(t, &row));
    CHECK_EQ(row, idx(t, "MOOD"));
    CHECK(!t.dirty());
    CHECK(e.setText(0, "z"));
    CHECK_EQ(t.remove({idx(t, "MOOD")}), size_t(1));
    CHECK(!e.apply(t, &row));  // the row is gone
    CHECK_EQ(row, npos);
    Table other = make({tf({{"MOOD", {"a"}}})});
    CHECK(!e.apply(other));  // another number of tracks
    PerTrackEdit none(t, 999);
    CHECK_EQ(none.size(), size_t(0));
    CHECK(!none.apply(t));
}

TEST(parse_value_text_rules) {
    CHECK_EQ(parse_value_text(" a ; b;;", true), (Values{"a", "b"}));
    CHECK_EQ(parse_value_text(" a ; b", false), Values{" a ; b"});
    CHECK_EQ(parse_value_text(" \t", false), Values{});
    CHECK_EQ(parse_value_text("", true), Values{});
}

int main() { return wpetest::run_all(); }
