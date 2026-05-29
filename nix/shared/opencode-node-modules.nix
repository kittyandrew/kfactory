{nodeModules}: ''
  runHook preConfigure
  cp -R ${nodeModules}/. .
  chmod -R u+w node_modules packages/*/node_modules
  patchShebangs node_modules packages/*/node_modules
  runHook postConfigure
''
