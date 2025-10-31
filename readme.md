# Atlas

The Atlas Package cloner. It manages project dependencies in an isolated `deps/` directory.

# Installation

Nim version 2.0 ships with `atlas`. Note that this version may be slightly outdated.

Building from source:

```sh
git clone https://github.com/nim-lang/atlas.git
cd atlas/
nim c src/atlas.nim
# copy src/atlas[.exe] somewhere in your PATH
```

If you're using Nimble you can install the latest Atlas with:

```sh
nimble install https://github.com/nim-lang/atlas@\#head
```

# Documentation

Read the [full documentation](./doc/atlas.md) or go through the following tutorial.

## Tutorial

Clone or create a Nim project. For example:

```sh
git clone git clone https://github.com/nim-lang/sat
cd sat/
atlas install
```

Tell Atlas we want to use the "malebolgia" library:

```sh
atlas use malebolgia
```

Now `import malebolgia` in your Nim code and run the compiler as usual:

```sh
echo "import malebolgia" >myproject.nim
nim c myproject.nim
```

## How it Works

Atlas works by creating a `nim.cfg` file with the proper compiler configs. No magic! Just delete `nim.cfg` to clear the configs.

The project structure will default to something similar to this:

```
  $project / project.nimble
  $project / nim.cfg
  $project / other main project files...
  $project / deps / atlas.config
  $project / deps / malebolgia
  $project / deps / dependency-A
  $project / deps / dependency-B
  $project / deps / dependency-C.nimble-link (for linked projects)
```

## Using URLs and local folders

Use URLs:
```sh
atlas use https://github.com/zedeus/nitter
```

Link to another project and its deps:
```sh
atlas link ../../existingDepdency/
```

## Manually Changing Deps

All dependencies are full git repos. You can manually go into `deps/` and change the branch, add new origins, make experimental changes, etc.

## Workspace Style Setup

Multiple projects can share a single deps folder.

In this configuration Atlas works in a *workspace* style.

To setup a folder `ws/` as a workspace simply clone a project into the `ws/` folder like:

```sh
mkdir ws/ && cd ws/
git clone https://github.com/nim-lang/choosenim
cd choosenim/
atlas --deps:../ --confdir:. init
atlas install
```

Now `ws/` contains all the dependencies for `choosenim` such as `zippy`, `checksums`, etc.

**Note**: The `deps` config setting can be relative or absolute. So you could do a global workspace like `atlas --deps:~/ws/ --confdir:. init`.

## Debugging

Sometimes it's helpful to understand what Atlas is doing. You can run commands with: `atlas --verbosity:<trace|debug>` to get more information. 

## Installing Nim with Atlas

```sh
atlas env 2.0.0
source deps/nim-2.0.0/activate.sh
```

## Dependencies

Atlas places dependencies in a `deps/` directory. This is especially helpful for working with projects that have dependencies pinned as git submodules, which was common in the pre-Atlas era.

The `deps/` directory contains:
- `atlas.config`: Configuration file for dependency management
- Individual dependency directories
- `nimble-link` files for linked projects

Note that `atlas.config` file can be placed in the main project directory as well. In this case, the dependencies directory can modified by setting the `deps` field.
