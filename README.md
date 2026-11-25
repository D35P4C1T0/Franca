# Franca

Franca is a focused rewrite of the [Carla](https://github.com/falkTX/Carla) standalone application for Arch Linux. It keeps Carla’s audio engine and plugin bridges and uses a Rust desktop interface built with Qt 6 and KDE Kirigami.

Use the Rack to arrange effects, edit parameters, and monitor per-plugin input and output levels. Use the Patchbay to connect the rack to your existing PipeWire/JACK graph, including a system-wide virtual microphone. Rack edits and patchbay cable changes support undo and redo.

Franca reads and writes Carla projects (`.carxp`) and can load Carla presets (`.carxs`). It uses the Carla settings namespace and default JACK client name to carry over plugin search paths, devices, and routes. When a project loads with missing plugins, save a recovered copy under a different name to preserve the original.

Franca hosts native and Wine-bridged plugins. Linux builds retain LV2, VST3, VST2, CLAP, LADSPA, DSSI, JSFX, SF2/SF3, SFZ, and Carla’s internal plugins. Some formats require optional system libraries.

Run `make` to build Franca on Linux. See [INSTALL.md](INSTALL.md) for dependencies, installation, Wine helpers, and smoke tests.

Licensed under the [GNU General Public License, version 2 or later](doc/GPL.txt).
