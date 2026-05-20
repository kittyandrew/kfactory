---
source: https://beeper.notion.site/Beeper-Go-Guidelines-ae943532d96f4ad6a614baf836c073eb
updated: Mar 30, 2026
custom-line-limit: 210
---

# Beeper Go Guidelines
<!-- Location: .claude/rules/00-project/031-beeper-go.md -- external reference, update
     by re-fetching from source URL. -->

The goal of this document is to describe how Beeper writes Go code. This includes code style, library choices, and other important guidelines.

# Style

The following style guidelines are meant to supplement existing style guides and to add additional emphasis on certain rules that are especially important for Beeper and elaborate on some rules that only apply to us.

Base style guides:

- [https://go.dev/doc/effective_go](https://go.dev/doc/effective_go)
- [https://go.dev/wiki/CodeReviewComments](https://go.dev/wiki/CodeReviewComments)

## General

- Use `any` instead of `interface{}`.
- Map iteration order is randomized, so slices are better when there's any chance of the order mattering (like HTTP routes).
- `http.StatusX` constants should always be used for status codes, don't write the raw code anywhere.

## Variables

- Variables should be `lowerCamelCase`.
- Use consistent casing for initialisms ([https://go.dev/wiki/CodeReviewComments#initialisms](https://go.dev/wiki/CodeReviewComments#initialisms))
- Prefer `var x type` over `x := type{}` for zero-value initializations.

## Control Flow

- Unnecessary nesting should be avoided. When handling errors or different cases, nest small blocks and don't nest the rest. In general, the “small block” should be the error handling case. ([https://github.com/golang/go/wiki/CodeReviewComments#indent-error-flow](https://github.com/golang/go/wiki/CodeReviewComments#indent-error-flow))

A corollary is that reading the left-aligned code should describe the happy-path.
    
    ```go
    // do this
    func stuff() error {
        err := couldError()
        if err != nil {
            return err
        }
        doThing()
        doOtherThing()
        doAnotherThing()
        return nil
    }
    
    // not this
    func stuff(thing bool) error {
        err := couldError()
        if err == nil {
            doThing()
            doOtherThing()
            doAnotherThing()
        }
        return err
    }
    ```
    
    - **Exception:** if there are multiple different conditions, and all of the blocks are short (a few lines), an `if` chain can be nicer. This is especially nice if all the conditions would need a `return` normally.
        
        ```go
        package main
        
        func erroringThing() (err error) {
          if err = stuff1(); err != nil {
            err = fmt.Errorf("failed to do thing #1: %w", err)
          } else if err = stuff2(); err != nil {
            err = fmt.Errorf("failed to do thing #2: %w", err)
          } else {
            fmt.Println("Success")
          }
          // implicitly return err
          return
        }
        
        ```
        

## Pre-Commit Hooks

The following pre-commit configuration should be used (replace `YOURSERV` with the name of your module). Run `pre-commit autoupgrade` to get the latest versions.

- Sample `pre-commit-config.yaml` file:
    
    ```yaml
    repos:
      - repo: https://github.com/pre-commit/pre-commit-hooks
        rev: v4.4.0
        hooks:
          - id: trailing-whitespace
            exclude_types: [markdown]
          - id: end-of-file-fixer
          - id: check-yaml
          - id: check-added-large-files
    
      - repo: https://github.com/tekwizely/pre-commit-golang
        rev: v1.0.0-rc.1
        hooks:
          - id: go-imports-repo
            args:
              - "-local"
              - "github.com/beeper/YOURSERV"
              - "-w"
          - id: go-vet-repo-mod
          - id: go-staticcheck-repo-mod
    ```
    

## Databases

- Prefer constant SQL query strings over sprintf'ing lots of dynamic parameters. Multiple functions to query the same table in different ways is usually better, especially if the places that call those functions only need one type of query.
- Database fields should be `NOT NULL` unless there's a good reason to allow nulls.
    - When allowing nulls, remember that scanning into a non-pointer string will not work, you have to use `sql.NullString` or a pointer to a pointer.
- When querying single rows, prefer `QueryRow` over `Query`
- Bubble database errors into the business logic code. Don’t suppress errors (for example by ignoring or just logging them).
    - Exception: `sql.ErrNoRows` should usually be suppressed and used to return nil for the actual value - just make sure callers handle the data being nil properly.

# Logging

See also: [Logging Standards](https://www.notion.so/Logging-Standards-41bff6689499409c8df09b9f97ba5cbf?pvs=21) 

- Use the https://github.com/rs/zerolog library and configure it using https://github.com/tulir/zeroconfig (N.B. libraries don’t need to configure loggers, they just need to accept loggers as parameters or from contexts - leave configuring to the “top-level” program).
- Don't use `Msgf` logs unless absolutely necessary. Structured logging allows for much richer ways of indicating the value of specific values.
- Log keys should be `snake_case`.
- Utilize the ability for zerolog to embed itself into the current `context.Context`.
    
    ```go
    func myFunc(ctx context.Context, userID id.UserID) error {
        log := zerolog.Ctx(ctx).With().
            Str("action", "myFunc").
            Str("user_id", userID.String()).
            Logger()
        ctx = log.WithContext(ctx)
        doSomeOtherCall(ctx)
        ...
        return nil
    }
    ```
    
- If there is a relevant error, always include it using `.Err`:
    
    ```go
    if err != nil {
        log.Err(err).Msg("thing failed") // automatically uses "error" log level
    }
    
    if err != nil {
        log.Warn().Err(err).Msg("thing failed")
    }
    ```
    
- In almost all circumstances, all errors should be logged in some fashion. If you ever have an `if err != nil` check, there should be a log line.
    - The main exception to this rule is if the error is immediately returned and the caller function logs the error.

## Log Levels

Zerolog supports leveled logging: [https://github.com/rs/zerolog#leveled-logging](https://github.com/rs/zerolog#leveled-logging) and we should use all of them (except for the `panic` level).

This StackOverflow answer has good descriptions of what each of the log levels should be used for.

[When to use the different log levels](https://stackoverflow.com/a/2031209/2319844)

Below are additional examples and descriptions more specific to our use-cases:

- **fatal** - should be used for errors that are not recoverable and will crash the service immediately. Examples include:
    - Failure to read/deserialize/validate the config when the service starts.
    - Failure to authenticate to a third-party service that is required for the service to run
    - The HTTP listener of a service crashes at any time.
- **error** - should be used for errors that the service can recover from, but which indicate a bug or unexpected behavior which should be investigated. Examples include:
    - Permanent failure of a network request that should always succeed.
    - Failure to decode JSON from an endpoint where we control the caller (if it’s user generated, we should use warn level).
    - Database query failures (the database is down or the query is bad).
- **warn** - should be used for errors/abnormal behaviors that the service can recover from and there is business logic to handle the failure gracefully. Examples include:
    - User-generated content is malformed. We want to warn here so that we can debug the caller more easily and understand was wrong.
    - Failure to retrieve non-essential piece of data from an external service/database.
    - Failure to perform an auxiliary/non-essential task as part of a task that succeeded otherwise.
- **info** - should be used to indicate important information related to normal behaviors of the service. Examples include:
    - Logging if a specific non-essential feature is disabled.
    - Logging the start/stop of long-running jobs within a service.
    - HTTP access logs.
    - Indicating the successful start/completion of a task.
- **debug** - should be used for information related to normal behaviors of the service that may be useful when reading through the logs to gain context about the behavior of the control flow. Examples include:
    - Logging reasons behind early returns/continues/breaks that may be confusing to debug later on. (Skipping X because Y.)
- **trace** - should be used for information related to normal behaviors of the service but which are unlikely to be helpful unless you are actively debugging that code. Most of our services disable trace logging in production (unless there’s a need for debugging). Examples include:
    - Logging state changes in verbose logs to a specific function to track down a bug that is only seen in production.
    - Logging things that developers may want to know about when developing locally but would not be useful in production logs.
    - Logging sensitive content is allowed on this level (and only this level), which means it must not be enabled in production other than manually targeted debugging where the user has approved it.

# Testing

- Use the [https://github.com/stretchr/testify/](https://github.com/stretchr/testify/) library
- Iterating over a slice is also a good way to do similar unit tests with different variables
[https://go.dev/blog/subtests#table-driven-tests-using-subtests](https://go.dev/blog/subtests#table-driven-tests-using-subtests)
- Use subtests (`t.Run`) liberally

# Server Library

- Servers should use the https://github.com/beeper/libserv library.
