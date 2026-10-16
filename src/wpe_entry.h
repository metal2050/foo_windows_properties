#pragma once
#include "fb2k.h"

#include <string>
#include <vector>

#ifndef WPE_VERSION
#define WPE_VERSION "1.0.0"
#endif

// Opens a new Properties (Windows style) window for the given tracks. Main thread only.
void wpe_open_properties(metadb_handle_list_cref items);

// Closes every open Properties window without writing anything. Called from initquit::on_quit, while the
// host services still exist, so the windows can unregister their callbacks before foobar2000 shuts its
// services down. Returns a line for the console about each window that still had unapplied changes (the
// quit prompt asks first; this is for a quit that did not go through it).
std::vector<std::string> wpe_close_all_windows();
