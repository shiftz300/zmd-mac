"""Small build helpers shared with isolated regression checks."""
import os
import subprocess


def apply_git_patch(patch, source):
    # Ignore a containing checkout (for example the Actions workspace). Otherwise
    # git apply can silently skip paths outside the checkout's current prefix.
    environment = dict(os.environ, GIT_CEILING_DIRECTORIES=str(source.resolve().parent))
    subprocess.run(["git", "apply", str(patch.resolve())], cwd=source,
                   env=environment, check=True)


def ensure_git_patch(patch, source):
    environment = dict(os.environ, GIT_CEILING_DIRECTORIES=str(source.resolve().parent))
    command = ["git", "apply"]
    # Unlike patch -R --batch, git never silently ignores the requested direction.
    if subprocess.run(command + ["--reverse", "--check", str(patch.resolve())],
                      cwd=source, env=environment, capture_output=True).returncode == 0:
        return
    subprocess.run(command + ["--check", str(patch.resolve())],
                   cwd=source, env=environment, check=True)
    apply_git_patch(patch, source)
