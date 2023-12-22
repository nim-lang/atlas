
import context

type
  Dependencies* = ref object
    deps*: seq[(PackageName, VersionInterval)]

  ProjectVersion* = object  # Represents a specific version of a project.
    version*: Version
    dependencies*: Dependencies

  # Represents a project, which consists of multiple versions.
  Project* = object
    pkg*: Package
    versions*: seq[ProjectVersion]

  Graph* = object
    projects*: seq[Project]

proc expand(g: var Graph) =
  ## Expand the graph by adding all dependencies.






