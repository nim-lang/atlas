
import asynchttpserver, asyncdispatch
import os, strutils, mimetypes

type
  GitRepo = object
    path: string
    name: string

proc handleRequest(req: Request) {.async.} =
  let path = getCurrentDir() / req.url.path.strip(chars={'/'})
  echo "http request: ", req.reqMethod, " path: ", path

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
  let port = 8080
  
  echo "Starting server on port ", port
  waitFor server.serve(Port(port), handleRequest)