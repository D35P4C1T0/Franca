// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

namespace franca_qt {
int run_qt_app();
}

extern "C" {
void franca_qt_set_cancelable_action(bool started,
                                     const char* message,
                                     void (*cancel_fn)(void*),
                                     void* cancel_ctx);
void franca_qt_update_cancelable_progress(int plugins_loaded);
void franca_qt_process_events();
bool franca_qt_grab_window(const char* output_path, int* out_width, int* out_height);
bool franca_qt_get_window_size(int* out_width, int* out_height);
bool franca_qt_resize_window(int width, int height);
}
