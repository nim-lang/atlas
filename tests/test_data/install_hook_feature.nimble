version = "1.0.0"

feature "testing":
  requires "featuredep >= 1.0.0"

feature "one", "two":
  requires "shareddep >= 1.0.0"

after install:
  discard
