{lib}: {
  mergeDisjointAttrs = context: sets:
    builtins.foldl' (acc: set: let
      duplicates = builtins.filter (name: builtins.hasAttr name acc) (builtins.attrNames set);
    in
      if duplicates != []
      then builtins.throw "${context}: duplicate attrs: ${lib.concatStringsSep ", " duplicates}"
      else acc // set) {}
    sets;
}
