#pragma once
// Where the "Properties (Windows style)…" context-menu item goes.
//
// contextmenu_manager (it builds both the host's own menus and any menu a UI component draws)
// groups every contextmenu_item_v2 under get_parent() and orders the children of one parent by
// get_sort_priority(), then by the GUID bytes in memory order. For a contextmenu_item the GUID is
// get_item_guid(0); for a contextmenu_group it is get_guid(). Only a contextmenu_group puts a
// separator (or a submenu) between children, so two items with the same parent sit next to each
// other with nothing in between.
//
// foobar2000 for Mac 2.26 registers its "Properties" item (class menu_props) with
//   get_parent()        = contextmenu_groups::root, not contextmenu_groups::properties
//   get_sort_priority() = 0, the contextmenu_item_v2 default
//   get_item_guid(0)    = {6F441057-1D18-4A58-9AC4-8F409CDA7DFD}
// Its other root items with priority 0 are "Copy name(s)" {FFE18008-...} (DEFAULT_OFF: hidden
// unless the user turns it on), "Copy" and "Collect" (FORCE_OFF, shortcuts only), and "Play on"
// {231A8A9F-...}. With the item's GUID {F17421F8-...} and priority 0 it would sort after both
// "Properties" and "Play on". A priority just below 0 puts it right before the visible priority-0
// root items, so directly above "Properties". The root groups all sit at -44 or lower (except
// legacy at 99 and properties at 100), so nothing the host registers lands in between.

#include "fb2k.h"

#include <cstring>

namespace wpe::menu {

// The host's built-in "Properties" context item.
inline constexpr double kHostPropertiesPriority = 0;
// {6F441057-1D18-4A58-9AC4-8F409CDA7DFD}
inline constexpr GUID kHostPropertiesGuid = {0x6f441057, 0x1d18, 0x4a58, {0x9a, 0xc4, 0x8f, 0x40, 0x9c, 0xda, 0x7d, 0xfd}};

// This component's context item. Keep this GUID (and the item text "Properties (Windows style)…" in
// component.cpp) across renames: key bindings and FooquX's menu defaults refer to them.
// {F17421F8-DCDE-4B32-89A4-BC47823D4DDE}
inline constexpr GUID kContextItemGuid = {0xf17421f8, 0xdcde, 0x4b32, {0x89, 0xa4, 0xbc, 0x47, 0x82, 0x3d, 0x4d, 0xde}};
// Same parent as the built-in item, a small step before it. The step is a normal (not subnormal)
// double so a flush-to-zero FPU mode cannot turn it into a tie, and it is far smaller than the
// whole-number priorities other components use.
inline constexpr double kContextItemPriority = kHostPropertiesPriority - 1.0 / 1024;
inline const GUID& context_item_parent() { return contextmenu_groups::root; }

// The order contextmenu_manager gives two children of the same parent.
inline bool sorts_before(double priorityA, const GUID& guidA, double priorityB, const GUID& guidB) {
    if (priorityA != priorityB) return priorityA < priorityB;
    return std::memcmp(&guidA, &guidB, sizeof(GUID)) < 0;
}

}
