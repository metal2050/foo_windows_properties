#include "fb2k.h"
#include "wpe_entry.h"
#include "wpe_menu.h"

// The component is called "Windows Properties"; its menu commands keep the text "Properties (Windows style)…"
// (kCommandName) and their GUIDs, so existing keyboard shortcuts and FooquX's menu relabel / P-key defaults,
// which match that exact text, keep working.
DECLARE_COMPONENT_VERSION(
    "Windows Properties",
    WPE_VERSION,
    "A Properties window that works like the foobar2000 for Windows Properties dialog, as a Mac window:\n"
    "Metadata, Details, ReplayGain and Artwork pages, Tools, Apply, Cancel and OK.\n"
    "\n"
    "Click a value (or press Return, F2 or just start typing) to edit it. Return or Tab saves and moves to the\n"
    "next field, Shift+Return / Shift+Tab go back, Escape cancels the edit. Delete removes a field, Insert or\n"
    "the \"add new\" row adds one, double-click a name to rename it. Command-Return is OK, Escape on the list is\n"
    "Cancel. Control-Tab or Command-1...4 switch pages. On the Artwork page, add, replace, paste, drop, export or remove\n"
    "embedded pictures (Space shows them in Quick Look; drag one out to save it as a file); nothing is written before\n"
    "OK or Apply. Closing the window or quitting foobar2000 with changes not yet applied asks first.\n"
    "\n"
    "Open it from the context menu or Edit menu: \"Properties (Windows style)\xE2\x80\xA6\".\n"
    "Bind a key under Preferences > Keyboard Shortcuts.");

namespace {

// {CF4EB47A-7E32-4759-8238-8AB8D4825896}
const GUID guid_main_command = {0xcf4eb47a, 0x7e32, 0x4759, {0x82, 0x38, 0x8a, 0xb8, 0xd4, 0x82, 0x58, 0x96}};

// Do not rename (see DECLARE_COMPONENT_VERSION above): matched by text by FooquX and shown in key bindings.
const char* const kCommandName = "Properties (Windows style)\xE2\x80\xA6";

class wpe_context_command : public contextmenu_item_simple {
public:
    unsigned get_num_items() override { return 1; }
    void get_item_name(unsigned, pfc::string_base& out) override { out = kCommandName; }
    void context_command(unsigned, metadb_handle_list_cref data, const GUID&) override { wpe_open_properties(data); }
    GUID get_item_guid(unsigned) override { return wpe::menu::kContextItemGuid; }
    bool get_item_description(unsigned, pfc::string_base& out) override {
        out = "Edits the tags of the selected tracks in a Windows-style Properties window.";
        return true;
    }
    // Directly above the built-in "Properties", in the same parent and with no separator between
    // them (see wpe_menu.h).
    GUID get_parent() override { return wpe::menu::context_item_parent(); }
    double get_sort_priority() override { return wpe::menu::kContextItemPriority; }
};
FB2K_SERVICE_FACTORY(wpe_context_command);

void current_selection(metadb_handle_list& out) {
    out.remove_all();
    try {
        ui_selection_manager_v2::get()->get_selection(out, ui_selection_manager_v2::flag_no_now_playing);
    } catch (...) {
        out.remove_all();
    }
    if (out.get_count() == 0) playlist_manager::get()->activeplaylist_get_selected_items(out);
}

class wpe_main_command : public mainmenu_commands {
public:
    t_uint32 get_command_count() override { return 1; }
    GUID get_command(t_uint32) override { return guid_main_command; }
    void get_name(t_uint32, pfc::string_base& out) override { out = kCommandName; }
    bool get_description(t_uint32, pfc::string_base& out) override {
        out = "Edits the tags of the selected tracks in a Windows-style Properties window.";
        return true;
    }
    GUID get_parent() override { return mainmenu_groups::edit; }
    t_uint32 get_sort_priority() override { return sort_priority_base; }
    bool get_display(t_uint32 index, pfc::string_base& text, t_uint32& flags) override {
        get_name(index, text);
        metadb_handle_list sel;
        current_selection(sel);
        flags = sel.get_count() ? 0 : flag_disabled;
        return true;
    }
    void execute(t_uint32, service_ptr_t<service_base>) override {
        metadb_handle_list sel;
        current_selection(sel);
        if (sel.get_count()) wpe_open_properties(sel);
    }
};
FB2K_SERVICE_FACTORY(wpe_main_command);

// macOS closes the remaining windows only after foobar2000 has shut its services down; a window that
// unregisters its metadb_io callback at that point makes foobar2000 abort. Close them while it is safe.
// Quitting asks about unapplied changes first (AppKit's document review, src/wpe_window.mm); a window
// that still has some here is closed without writing (a write during shutdown could be cut off), and the
// console says so.
class wpe_initquit : public initquit {
public:
    void on_quit() override {
        for (const std::string& note : wpe_close_all_windows()) FB2K_console_formatter() << "Windows Properties: " << note.c_str();
    }
};
FB2K_SERVICE_FACTORY(wpe_initquit);

}
