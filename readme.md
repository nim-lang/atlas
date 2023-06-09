# atlas
The Atlas Package cloner. It manages an isolated workspace that contains projects and dependencies.

# Installation

Upcoming Nim version 2.0 will ship with `atlas`. Building from source is unfortunately a bit complicated:

```
mkdir atlasbuild
cd atlasbuild
git clone https://github.com/nim-lang/nim.git
git clone https://github.com/nim-lang/atlas.git
cd atlas
nim c src/atlas.nim
# copy src/atlas[.exe] somewhere in your PATH
```
