// huh? — push-to-talk dictation and meeting transcription for Windows
// Copyright (C) 2026 getnsh
//
// This program is free software: you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free Software
// Foundation, either version 3 of the License, or (at your option) any later
// version. It is distributed WITHOUT ANY WARRANTY; see the GNU General Public
// License for details. You should have received a copy of the licence with this
// program; if not, see <https://www.gnu.org/licenses/>.

// No console window behind the app in a release build.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    huh_lib::run()
}
