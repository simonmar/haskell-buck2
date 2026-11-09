* Comments

- only comment when the reader needs to understand the "why", or
  when there's something that's not obvious from the local context.

- don't leave comments about previous approaches, unless it's a big
  pitfall to be avoided in the future.

- Respect abstraction boundaries in comments as you would in code.
  - Don't reference untracked files in any comments
  - In a generic component, don't reference the client or caller
    unless it's important to provide an example.

- when you do leave a comment, write it in plain, complete sentences
  that read easily the first time. Explain things clearly and give an
  example if that helps. In particular, avoid:
  - dropping the subject or verb ("A store package's are installed
    where its Paths module expects.")
  - packing a clause into a "by" or "as" phrase ("the directory, by
    the environment variable it looks at")
  - pronouns whose antecedent is far back or ambiguous ("the script
    that would tell them about their own")
  - unusual word order ("It says too which packages...")
  - chaining clauses with colons instead of writing separate sentences
  Longer is fine if it's clearer. A good test: could someone who doesn't
  know this code understand the comment on a single read?

  Before:
    # The build tools of the component are run from the compile, without
    # the script that would tell them about their own.
  After:
    # The compile runs a build tool's binary directly, not through the
    # wrapper script that sets its data-file variables, so the compile
    # has to set the tool's variables itself.

- much of the existing code is commented in the terse style described
  above. Don't copy it: new and edited comments should follow these
  rules even where nearby comments don't.
