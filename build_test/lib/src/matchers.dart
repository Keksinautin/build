// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';

import 'package:test/test.dart';

import 'package:build/build.dart';

/// Matches instance of [AssetNotFoundException].
final Matcher assetNotFoundException =
    const TypeMatcher<AssetNotFoundException>();

/// Matches instance of [InvalidInputException].
final Matcher invalidInputException =
    const TypeMatcher<InvalidInputException>();

/// Matches instance of [InvalidOutputException].
final Matcher invalidOutputException =
    const TypeMatcher<InvalidOutputException>();

/// Matches instance of [PackageNotFoundException].
final Matcher packageNotFoundException =
    const TypeMatcher<PackageNotFoundException>();

/// Decodes the value using [encoding] and matches it agains [expected].
Matcher decodedMatches(dynamic expected, {Encoding encoding}) =>
    new _DecodedMatcher(expected, encoding: encoding);

/// A matcher that decodes bytes and matches against the resulting string.
class _DecodedMatcher extends CustomMatcher {
  final Encoding _encoding;

  _DecodedMatcher(matcher, {Encoding encoding})
      : this._encoding = encoding ?? utf8,
        super('Utf8 decoded bytes', 'utf8.decode', matcher);

  @override
  featureValueOf(bytes) => _encoding.decode(bytes as List<int>);
}
