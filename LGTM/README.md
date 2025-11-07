
```markdown
# Loki and Tempo Password Creation

This guide provides the commands to create bcrypt-hashed password files for Loki and Tempo using `htpasswd`.

## Prerequisites

- `htpasswd` tool installed (from `apache2-utils` package)
- Access to a shell/terminal

## Create Password File for Loki

Generate a bcrypt hashed password file for Loki:

```

htpasswd -c -B loki-auth <username>

```

Replace `<username>` with your desired Loki username (e.g., `lokiuser`).

Example:

```

htpasswd -c -B loki-auth lokiuser

# Enter password

# Re-type password

```

This creates a file named `loki-auth` containing the hashed password for the Loki user.

## Create Password File for Tempo

Generate a bcrypt hashed password file for Tempo:

```

htpasswd -c -B tempo-auth <username>

```

Replace `<username>` with your desired Tempo username (e.g., `tempoadmin`).

Example:

```

htpasswd -c -B tempo-auth tempoadmin

# Enter password

# Re-type password

```

This creates a file named `tempo-auth` containing the hashed password for the Tempo user.
