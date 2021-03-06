// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:analyzer/analyzer.dart';
import 'package:build/build.dart';
import 'package:graphs/graphs.dart';
import 'package:path/path.dart' as p;
import 'package:json_annotation/json_annotation.dart';

import 'modules.dart';

part 'meta_module.g.dart';

/// Returns the top level directory in [path].
///
/// Throws an [ArgumentError] if [path] is just a filename with no directory.
String _topLevelDir(String path) {
  var parts = p.url.split(p.url.normalize(path));
  String error;
  if (parts.length == 1) {
    error = 'The path `$path` does not contain a directory.';
  } else if (parts.first == '..') {
    error = 'The path `$path` reaches outside the root directory.';
  }
  if (error != null) {
    throw new ArgumentError(
        'Cannot compute top level dir for path `$path`. $error');
  }
  return parts.first;
}

/// An [AssetId] and all of its internal/external deps based on it's
/// Directives.
///
/// Used to compute strongly connected components in the import graph for all
/// "internal" deps. Any "external" deps are ignored during that computation
/// since they are not allowed to be in a strongly connected component with
/// internal deps.
///
/// External deps are used to compute the dependent modules of each module once
/// the modules are decided.
///
/// Part files are also tracked here but ignored during computation of strongly
/// connected components, as they must always be a part of this assets module.
class _AssetNode {
  final AssetId id;

  /// The other internal sources that this file import or exports.
  ///
  /// These may be merged into the same Module as this node, and are used when
  /// computing strongly connected components.
  final Set<AssetId> internalDeps;

  /// Part files included by this asset.
  ///
  /// These should always be a part of the same connected component.
  final Set<AssetId> parts;

  /// The deps of this source that are from an external package.
  ///
  /// These are not used in computing strongly connected components (they are
  /// not allowed to be in a strongly connected component with any of our
  /// internal srcs).
  final Set<AssetId> externalDeps;

  _AssetNode(this.id, this.internalDeps, this.parts, this.externalDeps);

  /// Creates an [_AssetNode] for [id] given a parsed [CompilationUnit] and some
  /// [internalSrcs] which represent other assets that may become part of the
  /// same module.
  factory _AssetNode.forParsedUnit(
      AssetId id, CompilationUnit parsed, Set<AssetId> internalSrcs) {
    var externalDeps = new Set<AssetId>();
    var internalDeps = new Set<AssetId>();
    var parts = new Set<AssetId>();
    for (var directive in parsed.directives) {
      if (directive is! UriBasedDirective) continue;
      var path = (directive as UriBasedDirective).uri.stringValue;
      if (Uri.parse(path).scheme == 'dart') continue;
      var linkedId = new AssetId.resolve(path, from: id);
      if (linkedId == null) continue;
      if (directive is PartDirective) {
        if (!internalSrcs.contains(linkedId)) {
          throw new StateError(
              'Referenced part file $linkedId from $id which is not in the '
              'same package');
        }
        parts.add(linkedId);
        continue;
      }

      List<Configuration> conditionalDirectiveConfigurations;

      if (directive is ImportDirective && directive.configurations.isNotEmpty) {
        conditionalDirectiveConfigurations = directive.configurations;
      } else if (directive is ExportDirective &&
          directive.configurations.isNotEmpty) {
        conditionalDirectiveConfigurations = directive.configurations;
      }

      final allDeps = <AssetId>[linkedId];
      if (conditionalDirectiveConfigurations != null) {
        allDeps.addAll(conditionalDirectiveConfigurations
            .map((c) => Uri.parse(c.uri.stringValue))
            .where((u) => u.scheme != 'dart')
            .map((u) => new AssetId.resolve(u.toString(), from: id)));
      }

      for (var dep in allDeps) {
        if (internalSrcs.contains(dep)) {
          internalDeps.add(dep);
        } else {
          externalDeps.add(dep);
        }
      }
    }
    return new _AssetNode(id, internalDeps, parts, externalDeps);
  }
}

/// Creates a module based strictly off of a strongly connected component of
/// asset nodes.
///
/// This creates more modules than we want, but we collapse them later on.
Module _moduleForComponent(List<_AssetNode> componentNodes) {
  // Name components based on first alphabetically sorted node, preferring
  // public srcs (not under lib/src).
  var sources = componentNodes.map((n) => n.id).toSet();
  var nonSrcIds = sources.where((id) => !id.path.startsWith('lib/src/'));
  var primaryId =
      nonSrcIds.isNotEmpty ? nonSrcIds.reduce(_min) : sources.reduce(_min);
  // Expand to include all the part files of each node, these aren't
  // included as individual `_AssetNodes`s in `connectedComponents`.
  sources.addAll(componentNodes.expand((n) => n.parts));
  var directDependencies = new Set<AssetId>()
    ..addAll(componentNodes.expand((n) => n.externalDeps))
    ..addAll(componentNodes.expand((n) => n.internalDeps))
    ..removeAll(sources);
  return new Module(primaryId, sources, directDependencies);
}

Map<AssetId, Module> _entryPointModules(
        Iterable<Module> modules, Set<AssetId> entrypoints) =>
    new Map.fromIterable(
        modules.where((m) => m.sources.any(entrypoints.contains)),
        key: (m) => (m as Module).primarySource);

/// Gets the local (same top level dir of the same package) transitive deps of
/// [module] using [assetsToModules].
Set<AssetId> _localTransitiveDeps(
    Module module, Map<AssetId, Module> assetsToModules) {
  var localTransitiveDeps = new Set<AssetId>();
  var nextIds = module.directDependencies;
  var seenIds = new Set<AssetId>();
  while (nextIds.isNotEmpty) {
    var ids = nextIds;
    seenIds.addAll(ids);
    nextIds = new Set<AssetId>();
    for (var id in ids) {
      var module = assetsToModules[id];
      if (module == null) continue; // Skip non-local modules
      if (localTransitiveDeps.add(module.primarySource)) {
        nextIds.addAll(module.directDependencies.difference(seenIds));
      }
    }
  }
  return localTransitiveDeps;
}

/// Creates a map of modules to the entrypoint modules that transitively
/// depend on those modules.
Map<AssetId, Set<AssetId>> _findReverseEntrypointDeps(
    Iterable<Module> entrypointModules, Iterable<Module> modules) {
  var reverseDeps = <AssetId, Set<AssetId>>{};
  var assetsToModules = <AssetId, Module>{};
  for (var module in modules) {
    for (var assetId in module.sources) {
      assetsToModules[assetId] = module;
    }
  }
  for (var module in entrypointModules) {
    for (var moduleDep in _localTransitiveDeps(module, assetsToModules)) {
      reverseDeps
          .putIfAbsent(moduleDep, () => new Set<AssetId>())
          .add(module.primarySource);
    }
  }
  return reverseDeps;
}

/// Merges [modules] into a minimum set of [Module]s using the
/// following rules:
///
///   * If it is an entrypoint module do not merge it.
///   * If it is not depended on my any entrypoint do not merge it.
///   * If it is depended on by no entrypoint merge it into the entrypoint
///   modules
///   * Else merge it into with others that are depended on by the same set of
///   entrypoints
List<Module> _mergeModules(Iterable<Module> modules, Set<AssetId> entrypoints) {
  // Modules which have any entrypoing keyed by primary source.
  var entrypointModules = _entryPointModules(modules, entrypoints);

  // Maps modules to entrypoint modules that transitively depend on them.
  var modulesToEntryPoints =
      _findReverseEntrypointDeps(entrypointModules.values, modules);

  // Modules which are not depended on by any entrypoint
  var standaloneModules = <Module>[];

  // Modules which are merged with others.
  var mergedModules = <String, Module>{};

  for (var module in modules) {
    // Skip entrypoint modules.
    if (entrypointModules.containsKey(module.primarySource)) continue;

    // The entry points that transitively import this module.
    var entrypointIds = modulesToEntryPoints[module.primarySource];

    // If no entrypoint imports the module, just leave it alone.
    if (entrypointIds == null || entrypointIds.isEmpty) {
      standaloneModules.add(module);
      continue;
    }

    // If there are multiple entry points for a given resource we must create
    // a new shared module. Use `$` to signal that it is a shared module.
    if (entrypointIds.length > 1) {
      var mId = (entrypointIds.toList()..sort()).map((m) => m.path).join('\$');
      if (mergedModules.containsKey(mId)) {
        mergedModules[mId].merge(module);
      } else {
        mergedModules[mId] = module;
      }
    } else {
      entrypointModules[entrypointIds.single].merge(module);
    }
  }

  return mergedModules.values
      .map(_withConsistentPrimarySource)
      .followedBy(entrypointModules.values)
      .followedBy(standaloneModules)
      .toList();
}

Module _withConsistentPrimarySource(Module m) =>
    new Module(m.sources.reduce(_min), m.sources, m.directDependencies);

T _min<T extends Comparable<T>>(T a, T b) => a.compareTo(b) < 0 ? a : b;

// Returns whether [dart] contains a [PartOfDirective].
bool _isPart(CompilationUnit dart) =>
    dart.directives.any((directive) => directive is PartOfDirective);

/// Returns whether [dart] looks like an entrypoint file.
bool _isEntrypoint(CompilationUnit dart) {
  return dart.declarations.any((node) {
    return node is FunctionDeclaration &&
        node.name.name == 'main' &&
        node.functionExpression.parameters.parameters.length <= 2;
  });
}

Future<List<Module>> _computeModules(
    AssetReader reader, List<AssetId> assets, bool public) async {
  var dir = _topLevelDir(assets.first.path);
  if (!assets.every((src) => _topLevelDir(src.path) == dir)) {
    throw new ArgumentError(
        'All srcs must live in the same top level directory.');
  }

  // The set of entry points from `srcAssets` based on `mode`.
  var entryIds = new Set<AssetId>();
  // All the `srcAssets` that are part files.
  var partIds = new Set<AssetId>();
  // Invalid assets that should be removed from `srcAssets` after this loop.
  var idsToRemove = <AssetId>[];
  var parsedAssetsById = <AssetId, CompilationUnit>{};
  for (var asset in assets) {
    var content = await reader.readAsString(asset);
    // Skip errors here, dartdevc gives nicer messages.
    var parsed = public
        ? parseDirectives(content, name: asset.path, suppressErrors: true)
        : parseCompilationUnit(content,
            name: asset.path, suppressErrors: true, parseFunctionBodies: false);
    parsedAssetsById[asset] = parsed;

    // Skip any files which contain a `dart:_` import.
    if (parsed.directives.any((d) =>
        d is UriBasedDirective &&
        d.uri.stringValue.startsWith('dart:_') &&
        asset.package != 'dart_internal')) {
      idsToRemove.add(asset);
      continue;
    }

    // Short-circuit for part files.
    if (_isPart(parsed)) {
      partIds.add(asset);
      continue;
    }

    if (public) {
      if (!asset.path.startsWith('lib/src/')) entryIds.add(asset);
    } else {
      if (_isEntrypoint(parsed)) entryIds.add(asset);
    }
  }

  var trimedAssets =
      assets.where((asset) => !idsToRemove.contains(asset)).toList();
  assets = trimedAssets;
  // Build the `_AssetNode`s for each asset, skipping part files.
  var nodesById = <AssetId, _AssetNode>{};
  var srcAssetIds = assets.map((asset) => asset).toSet();
  var nonPartAssets = assets.where((asset) => !partIds.contains(asset));
  for (var asset in nonPartAssets) {
    var node = new _AssetNode.forParsedUnit(
        asset, parsedAssetsById[asset], srcAssetIds);
    nodesById[asset] = node;
  }

  var connectedComponents = stronglyConnectedComponents<AssetId, _AssetNode>(
      nodesById.values,
      (n) => n.id,
      (n) => n.internalDeps.map((dep) => nodesById[dep]));
  return _mergeModules(connectedComponents.map(_moduleForComponent), entryIds);
}

@JsonSerializable()
class MetaModule extends Object with _$MetaModuleSerializerMixin {
  @override
  @JsonKey(name: 'm', nullable: false)
  final List<Module> modules;

  MetaModule(this.modules);

  /// Generated factory constructor.
  factory MetaModule.fromJson(Map<String, dynamic> json) =>
      _$MetaModuleFromJson(json);

  static Future<MetaModule> forAssets(
      AssetReader reader, List<AssetId> assets) async {
    var assetsByTopLevel = <String, List<AssetId>>{};
    for (var asset in assets) {
      var dir = _topLevelDir(asset.path);
      if (!assetsByTopLevel.containsKey(dir)) {
        assetsByTopLevel[dir] = <AssetId>[];
      }
      assetsByTopLevel[dir].add(asset);
    }
    var modules = <Module>[];
    for (var key in assetsByTopLevel.keys) {
      modules.addAll(
          await _computeModules(reader, assetsByTopLevel[key], key == 'lib'));
    }
    // Deterministically output the modules.
    modules.sort((a, b) => a.primarySource.compareTo(b.primarySource));
    return new MetaModule(modules);
  }
}
