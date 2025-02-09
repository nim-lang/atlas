
import asynchttpserver, asyncdispatch
import os, strutils, mimetypes

type
  GitRepo = object
    path: string
    name: string

var searchDirs: seq[string]

proc findDir(org, repo, files: string): string =
  {.cast(gcsafe).}:
    # search for org matches first
    for dir in searchDirs:
      result = dir / org / repo / files
      # echo "searching: ", result
      if dirExists(dir / org / repo):
        return
    # otherwise try without org in the searchdir
    for dir in searchDirs:
      result = dir / repo / files
      # echo "searching: ", result
      if dirExists(dir / repo):
        return
    
    if not repo.endsWith(".git"):
      return findDir(org, repo & ".git", files)

proc handleRequest(req: Request) {.async.} =
  echo "http request: ", req.reqMethod, " url: ", req.url.path

  let arg = req.url.path.strip(chars={'/'})
  var path: string
  try:
    let dirs = arg.split('/')
    let org = dirs[0]
    let repo = dirs[1]
    let files = dirs[2..^1].join($DirSep)
    path = findDir(org, repo, files)
    echo "http repo: ", " repo: ", repo, " path: ", path
  except IndexDefect:
    {.cast(gcsafe).}:
      path = searchDirs[0] / arg

  # Serve static files if not a git request
  if fileExists(path):
    let ext = splitFile(path).ext
    var contentType = newMimetypes().getMimetype(ext.strip(chars={'.'}))
    if contentType == "": contentType = "application/octet-stream"
    
    var headers = newHttpHeaders()
    headers["Content-Type"] = contentType
    
    let content = readFile(path)
    await req.respond(Http200, content, headers)
  else:
    await req.respond(Http404, "File not found")

when isMainModule:

  let server = newAsyncHttpServer()
  let port = 4242
  
  for arg in commandLineParams():
    if dirExists(arg):
      searchDirs.add(arg.absolutePath)

  doAssert searchDirs.len() >= 1, "must provide at least one directory to serve repos from"
  echo "Starting server on port ", port
  waitFor server.serve(Port(port), handleRequest)