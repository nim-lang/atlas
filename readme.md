# atlas
The Atlas Package cloner. It manages project dependencies in an isolated `deps/` directory.

# Installation

Upcoming Nim version 2.0 will ship with `atlas`. Building from source:

```sh
git clone https://github.com/nim-lang/atlas.git
cd atlas
nim c src/atlas.nim
# copy src/atlas[.exe] somewhere in your PATH
```

# Documentation

Read the [full documentation](./doc/atlas.md) or go through the following tutorial.

## Tutorial

Create a new project. A project contains everything we need and can safely be deleted after
this tutorial:

```sh
mkdir project
cd project
atlas init
```

Create a new project inside the project:

```sh
mkdir myproject
cd myproject
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

The project structure looks like this:

```
  $project / project.nimble
  $project / nim.cfg
  $project / other main project files...
  $project / deps / atlas.config
  $project / deps / dependency-A
  $project / deps / dependency-B
  $project / deps / dependency-C.nimble-link (for linked projects)
```

## Using URLs and local folders

```sh
atlas use https://github.com/zedeus/nitter
atlas link ../../existingDepdency/
```

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
