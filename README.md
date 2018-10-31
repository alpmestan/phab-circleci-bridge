This project implements a little webservice meant to act as
a bridge between GHC's Phabricator and Circle CI builds.

# Building

This project can be built with `cabal new-build`. However, the
`cabal.project` file assumes you have my branch of the `circlehs`
library forked in this project's top directory, under `circlehs/`.

My branch of circlehs: https://github.com/alpmestan/circlehs

# Usage

``` sh
$ phab-circleci-bridge <configuration file>
```

where the config file should look like this.

``` sh
github_repo_user = "ghc" # this is the default, when omitted
github_repo_project = "ghc-diffs" # this is the default, when omitted
circle_api_token = "abcdef" # mandatory, no default value
phabricator_api_token = "abcdef" # mandatory, no default value
http_port = 8080 # this the default, when omitted
state_file = "./builds.bin" # this is the default, when omitted
work_dir = "./repos/"
```

Only the API token entries are mandatory.

It is recommended to send stderr to a file when running it, as the
application happily reports a whole lot of things there which might be
valuable for debugging.

# Workflow

- Phabricator receives a new diff (or an update to an existing one)
- It issues a "Make HTTP request" build step to this webservice,
  automatically sending over a few necessary details about the
  patch, where to find it, etc.
- The service receives the said request and pushes a branch to
  https://github.com/ghc/ghc-diffs that mirrors the staging
  branch for the diff.
- The service issues a build request to Circle CI, pointing to
  the suitable branch of the `ghc-diffs` repo and specifying the
  right job type, etc.
- The service pushes the appropriate details in a job queue which
  is scanned at regular intervals, asking the status to
  Circle CI for every single build we're watching.
- When we get new information, we send update messages to Phabricator.
- When a build is done (whatever the reason, build
  success/failure/time out), we let Phabricator know and report
  success/failure appropriately, finally removing that build from the
  queue, the branch from `ghc-diffs`, etc.

**IMPORTANT**: In particular, this means we will want to configure as many
different Phabricator "build steps" as job types we want to run. One would
hit /validate-x86_64-linux, another would run hadrian on linux, another freebsd,
etc.
