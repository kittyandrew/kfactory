{
  pkgs,
  nodeModules,
}: ''
    runHook preConfigure
    ln -s ${nodeModules}/node_modules node_modules
    stage_node_modules() {
      modules="$1"
      rel="$2"
      mkdir -p "$rel"

      if [ -d "$modules/.bin" ]; then
        mkdir -p "$rel/.bin"
        for bin in "$modules"/.bin/*; do
          if [ -e "$bin" ]; then
            target="$(readlink -f "$bin")"
            wrapper="$rel/.bin/$(basename "$bin")"
            shebang=""
            IFS= read -r shebang < "$target" || true
            if [[ "$shebang" == *node* ]]; then
              cat > "$wrapper" <<EOF
  #!${pkgs.runtimeShell}
  exec ${pkgs.nodejs}/bin/node "$target" "\$@"
  EOF
              chmod +x "$wrapper"
            else
              cp -L "$bin" "$wrapper"
            fi
          fi
        done
        patchShebangs "$rel/.bin"
      fi

      for entry in "$modules"/*; do
        if [ -e "$entry" ]; then
          name="$(basename "$entry")"
          if [ "$name" != @opencode-ai ]; then
            ln -s "$entry" "$rel/$name"
          fi
        fi
      done
    }

    link_workspace_package() {
      rel="$1"
      name="$2"
      fallback="$3"
      case "$name" in
        core|http-recorder|llm|plugin|script|ui)
          ln -s "$PWD/packages/$name" "$rel/@opencode-ai/$name"
          ;;
        sdk)
          ln -s "$PWD/packages/sdk/js" "$rel/@opencode-ai/sdk"
          ;;
        *)
          ln -s "$fallback" "$rel/@opencode-ai/$name"
          ;;
      esac
    }

    link_workspace_packages() {
      modules="$1"
      rel="$2"
      if [ -d "$modules/@opencode-ai" ]; then
        mkdir -p "$rel/@opencode-ai"
        for package in "$modules"/@opencode-ai/*; do
          if [ -e "$package" ]; then
            link_workspace_package "$rel" "$(basename "$package")" "$package"
          fi
        done
      fi
    }

    while IFS= read -r modules; do
      rel="''${modules#${nodeModules}/}"
      mkdir -p "$(dirname "$rel")"
      stage_node_modules "$modules" "$rel"
      link_workspace_packages "$modules" "$rel"
    done < <(find ${nodeModules}/packages -type d -name node_modules)
    runHook postConfigure
''
