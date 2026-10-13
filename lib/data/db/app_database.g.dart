// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $DoubanCachesTable extends DoubanCaches
    with TableInfo<$DoubanCachesTable, DoubanCache> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DoubanCachesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _expiresAtMeta = const VerificationMeta(
    'expiresAt',
  );
  @override
  late final GeneratedColumn<int> expiresAt = GeneratedColumn<int>(
    'expires_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _savedAtMeta = const VerificationMeta(
    'savedAt',
  );
  @override
  late final GeneratedColumn<int> savedAt = GeneratedColumn<int>(
    'saved_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value, expiresAt, savedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'douban_caches';
  @override
  VerificationContext validateIntegrity(
    Insertable<DoubanCache> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    if (data.containsKey('expires_at')) {
      context.handle(
        _expiresAtMeta,
        expiresAt.isAcceptableOrUnknown(data['expires_at']!, _expiresAtMeta),
      );
    } else if (isInserting) {
      context.missing(_expiresAtMeta);
    }
    if (data.containsKey('saved_at')) {
      context.handle(
        _savedAtMeta,
        savedAt.isAcceptableOrUnknown(data['saved_at']!, _savedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_savedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  DoubanCache map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DoubanCache(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
      expiresAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}expires_at'],
      )!,
      savedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}saved_at'],
      )!,
    );
  }

  @override
  $DoubanCachesTable createAlias(String alias) {
    return $DoubanCachesTable(attachedDatabase, alias);
  }
}

class DoubanCache extends DataClass implements Insertable<DoubanCache> {
  /// 业务键（调用方保证唯一）
  final String key;

  /// 原始 JSON 响应正文
  final String value;

  /// 过期时刻（Unix 秒）。<= 当前时间即为过期。
  final int expiresAt;

  /// 写入时刻（Unix 秒）。仅用于诊断/统计，不参与过期判断。
  final int savedAt;
  const DoubanCache({
    required this.key,
    required this.value,
    required this.expiresAt,
    required this.savedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    map['expires_at'] = Variable<int>(expiresAt);
    map['saved_at'] = Variable<int>(savedAt);
    return map;
  }

  DoubanCachesCompanion toCompanion(bool nullToAbsent) {
    return DoubanCachesCompanion(
      key: Value(key),
      value: Value(value),
      expiresAt: Value(expiresAt),
      savedAt: Value(savedAt),
    );
  }

  factory DoubanCache.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DoubanCache(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
      expiresAt: serializer.fromJson<int>(json['expiresAt']),
      savedAt: serializer.fromJson<int>(json['savedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
      'expiresAt': serializer.toJson<int>(expiresAt),
      'savedAt': serializer.toJson<int>(savedAt),
    };
  }

  DoubanCache copyWith({
    String? key,
    String? value,
    int? expiresAt,
    int? savedAt,
  }) => DoubanCache(
    key: key ?? this.key,
    value: value ?? this.value,
    expiresAt: expiresAt ?? this.expiresAt,
    savedAt: savedAt ?? this.savedAt,
  );
  DoubanCache copyWithCompanion(DoubanCachesCompanion data) {
    return DoubanCache(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
      expiresAt: data.expiresAt.present ? data.expiresAt.value : this.expiresAt,
      savedAt: data.savedAt.present ? data.savedAt.value : this.savedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DoubanCache(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('expiresAt: $expiresAt, ')
          ..write('savedAt: $savedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value, expiresAt, savedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DoubanCache &&
          other.key == this.key &&
          other.value == this.value &&
          other.expiresAt == this.expiresAt &&
          other.savedAt == this.savedAt);
}

class DoubanCachesCompanion extends UpdateCompanion<DoubanCache> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> expiresAt;
  final Value<int> savedAt;
  final Value<int> rowid;
  const DoubanCachesCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.expiresAt = const Value.absent(),
    this.savedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  DoubanCachesCompanion.insert({
    required String key,
    required String value,
    required int expiresAt,
    required int savedAt,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value),
       expiresAt = Value(expiresAt),
       savedAt = Value(savedAt);
  static Insertable<DoubanCache> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? expiresAt,
    Expression<int>? savedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (expiresAt != null) 'expires_at': expiresAt,
      if (savedAt != null) 'saved_at': savedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  DoubanCachesCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? expiresAt,
    Value<int>? savedAt,
    Value<int>? rowid,
  }) {
    return DoubanCachesCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      expiresAt: expiresAt ?? this.expiresAt,
      savedAt: savedAt ?? this.savedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (expiresAt.present) {
      map['expires_at'] = Variable<int>(expiresAt.value);
    }
    if (savedAt.present) {
      map['saved_at'] = Variable<int>(savedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DoubanCachesCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('expiresAt: $expiresAt, ')
          ..write('savedAt: $savedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PlayHistoriesTable extends PlayHistories
    with TableInfo<$PlayHistoriesTable, PlayHistory> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PlayHistoriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _itemIdMeta = const VerificationMeta('itemId');
  @override
  late final GeneratedColumn<String> itemId = GeneratedColumn<String>(
    'item_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _positionTicksMeta = const VerificationMeta(
    'positionTicks',
  );
  @override
  late final GeneratedColumn<int> positionTicks = GeneratedColumn<int>(
    'position_ticks',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _runtimeTicksMeta = const VerificationMeta(
    'runtimeTicks',
  );
  @override
  late final GeneratedColumn<int> runtimeTicks = GeneratedColumn<int>(
    'runtime_ticks',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _playedAtMeta = const VerificationMeta(
    'playedAt',
  );
  @override
  late final GeneratedColumn<int> playedAt = GeneratedColumn<int>(
    'played_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    itemId,
    name,
    type,
    positionTicks,
    runtimeTicks,
    playedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'play_histories';
  @override
  VerificationContext validateIntegrity(
    Insertable<PlayHistory> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('item_id')) {
      context.handle(
        _itemIdMeta,
        itemId.isAcceptableOrUnknown(data['item_id']!, _itemIdMeta),
      );
    } else if (isInserting) {
      context.missing(_itemIdMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    }
    if (data.containsKey('position_ticks')) {
      context.handle(
        _positionTicksMeta,
        positionTicks.isAcceptableOrUnknown(
          data['position_ticks']!,
          _positionTicksMeta,
        ),
      );
    }
    if (data.containsKey('runtime_ticks')) {
      context.handle(
        _runtimeTicksMeta,
        runtimeTicks.isAcceptableOrUnknown(
          data['runtime_ticks']!,
          _runtimeTicksMeta,
        ),
      );
    }
    if (data.containsKey('played_at')) {
      context.handle(
        _playedAtMeta,
        playedAt.isAcceptableOrUnknown(data['played_at']!, _playedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_playedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {itemId};
  @override
  PlayHistory map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PlayHistory(
      itemId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}item_id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}type'],
      )!,
      positionTicks: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}position_ticks'],
      )!,
      runtimeTicks: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}runtime_ticks'],
      )!,
      playedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}played_at'],
      )!,
    );
  }

  @override
  $PlayHistoriesTable createAlias(String alias) {
    return $PlayHistoriesTable(attachedDatabase, alias);
  }
}

class PlayHistory extends DataClass implements Insertable<PlayHistory> {
  final String itemId;

  /// 冗余存名称/类型/时长：列表渲染时无需回查 Emby，
  /// 断网也能显示"最近播放"。
  final String name;
  final String type;

  /// 播放位置与总时长（ticks，1 tick = 100ns，与 Emby 口径一致）
  final int positionTicks;
  final int runtimeTicks;

  /// 最后一次播放时刻（Unix 秒）
  final int playedAt;
  const PlayHistory({
    required this.itemId,
    required this.name,
    required this.type,
    required this.positionTicks,
    required this.runtimeTicks,
    required this.playedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['item_id'] = Variable<String>(itemId);
    map['name'] = Variable<String>(name);
    map['type'] = Variable<String>(type);
    map['position_ticks'] = Variable<int>(positionTicks);
    map['runtime_ticks'] = Variable<int>(runtimeTicks);
    map['played_at'] = Variable<int>(playedAt);
    return map;
  }

  PlayHistoriesCompanion toCompanion(bool nullToAbsent) {
    return PlayHistoriesCompanion(
      itemId: Value(itemId),
      name: Value(name),
      type: Value(type),
      positionTicks: Value(positionTicks),
      runtimeTicks: Value(runtimeTicks),
      playedAt: Value(playedAt),
    );
  }

  factory PlayHistory.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PlayHistory(
      itemId: serializer.fromJson<String>(json['itemId']),
      name: serializer.fromJson<String>(json['name']),
      type: serializer.fromJson<String>(json['type']),
      positionTicks: serializer.fromJson<int>(json['positionTicks']),
      runtimeTicks: serializer.fromJson<int>(json['runtimeTicks']),
      playedAt: serializer.fromJson<int>(json['playedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'itemId': serializer.toJson<String>(itemId),
      'name': serializer.toJson<String>(name),
      'type': serializer.toJson<String>(type),
      'positionTicks': serializer.toJson<int>(positionTicks),
      'runtimeTicks': serializer.toJson<int>(runtimeTicks),
      'playedAt': serializer.toJson<int>(playedAt),
    };
  }

  PlayHistory copyWith({
    String? itemId,
    String? name,
    String? type,
    int? positionTicks,
    int? runtimeTicks,
    int? playedAt,
  }) => PlayHistory(
    itemId: itemId ?? this.itemId,
    name: name ?? this.name,
    type: type ?? this.type,
    positionTicks: positionTicks ?? this.positionTicks,
    runtimeTicks: runtimeTicks ?? this.runtimeTicks,
    playedAt: playedAt ?? this.playedAt,
  );
  PlayHistory copyWithCompanion(PlayHistoriesCompanion data) {
    return PlayHistory(
      itemId: data.itemId.present ? data.itemId.value : this.itemId,
      name: data.name.present ? data.name.value : this.name,
      type: data.type.present ? data.type.value : this.type,
      positionTicks: data.positionTicks.present
          ? data.positionTicks.value
          : this.positionTicks,
      runtimeTicks: data.runtimeTicks.present
          ? data.runtimeTicks.value
          : this.runtimeTicks,
      playedAt: data.playedAt.present ? data.playedAt.value : this.playedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PlayHistory(')
          ..write('itemId: $itemId, ')
          ..write('name: $name, ')
          ..write('type: $type, ')
          ..write('positionTicks: $positionTicks, ')
          ..write('runtimeTicks: $runtimeTicks, ')
          ..write('playedAt: $playedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(itemId, name, type, positionTicks, runtimeTicks, playedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlayHistory &&
          other.itemId == this.itemId &&
          other.name == this.name &&
          other.type == this.type &&
          other.positionTicks == this.positionTicks &&
          other.runtimeTicks == this.runtimeTicks &&
          other.playedAt == this.playedAt);
}

class PlayHistoriesCompanion extends UpdateCompanion<PlayHistory> {
  final Value<String> itemId;
  final Value<String> name;
  final Value<String> type;
  final Value<int> positionTicks;
  final Value<int> runtimeTicks;
  final Value<int> playedAt;
  final Value<int> rowid;
  const PlayHistoriesCompanion({
    this.itemId = const Value.absent(),
    this.name = const Value.absent(),
    this.type = const Value.absent(),
    this.positionTicks = const Value.absent(),
    this.runtimeTicks = const Value.absent(),
    this.playedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PlayHistoriesCompanion.insert({
    required String itemId,
    this.name = const Value.absent(),
    this.type = const Value.absent(),
    this.positionTicks = const Value.absent(),
    this.runtimeTicks = const Value.absent(),
    required int playedAt,
    this.rowid = const Value.absent(),
  }) : itemId = Value(itemId),
       playedAt = Value(playedAt);
  static Insertable<PlayHistory> custom({
    Expression<String>? itemId,
    Expression<String>? name,
    Expression<String>? type,
    Expression<int>? positionTicks,
    Expression<int>? runtimeTicks,
    Expression<int>? playedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (itemId != null) 'item_id': itemId,
      if (name != null) 'name': name,
      if (type != null) 'type': type,
      if (positionTicks != null) 'position_ticks': positionTicks,
      if (runtimeTicks != null) 'runtime_ticks': runtimeTicks,
      if (playedAt != null) 'played_at': playedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PlayHistoriesCompanion copyWith({
    Value<String>? itemId,
    Value<String>? name,
    Value<String>? type,
    Value<int>? positionTicks,
    Value<int>? runtimeTicks,
    Value<int>? playedAt,
    Value<int>? rowid,
  }) {
    return PlayHistoriesCompanion(
      itemId: itemId ?? this.itemId,
      name: name ?? this.name,
      type: type ?? this.type,
      positionTicks: positionTicks ?? this.positionTicks,
      runtimeTicks: runtimeTicks ?? this.runtimeTicks,
      playedAt: playedAt ?? this.playedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (itemId.present) {
      map['item_id'] = Variable<String>(itemId.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (positionTicks.present) {
      map['position_ticks'] = Variable<int>(positionTicks.value);
    }
    if (runtimeTicks.present) {
      map['runtime_ticks'] = Variable<int>(runtimeTicks.value);
    }
    if (playedAt.present) {
      map['played_at'] = Variable<int>(playedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PlayHistoriesCompanion(')
          ..write('itemId: $itemId, ')
          ..write('name: $name, ')
          ..write('type: $type, ')
          ..write('positionTicks: $positionTicks, ')
          ..write('runtimeTicks: $runtimeTicks, ')
          ..write('playedAt: $playedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CalendarSubscriptionsTable extends CalendarSubscriptions
    with TableInfo<$CalendarSubscriptionsTable, CalendarSubscription> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CalendarSubscriptionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  @override
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sourceIdMeta = const VerificationMeta(
    'sourceId',
  );
  @override
  late final GeneratedColumn<String> sourceId = GeneratedColumn<String>(
    'source_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _mediaTypeMeta = const VerificationMeta(
    'mediaType',
  );
  @override
  late final GeneratedColumn<String> mediaType = GeneratedColumn<String>(
    'media_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('tv'),
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleCnMeta = const VerificationMeta(
    'titleCn',
  );
  @override
  late final GeneratedColumn<String> titleCn = GeneratedColumn<String>(
    'title_cn',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _posterUrlMeta = const VerificationMeta(
    'posterUrl',
  );
  @override
  late final GeneratedColumn<String> posterUrl = GeneratedColumn<String>(
    'poster_url',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _platformMeta = const VerificationMeta(
    'platform',
  );
  @override
  late final GeneratedColumn<String> platform = GeneratedColumn<String>(
    'platform',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _categoryMeta = const VerificationMeta(
    'category',
  );
  @override
  late final GeneratedColumn<String> category = GeneratedColumn<String>(
    'category',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('series'),
  );
  static const VerificationMeta _lastAirDateMeta = const VerificationMeta(
    'lastAirDate',
  );
  @override
  late final GeneratedColumn<String> lastAirDate = GeneratedColumn<String>(
    'last_air_date',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _syncedToServerMeta = const VerificationMeta(
    'syncedToServer',
  );
  @override
  late final GeneratedColumn<bool> syncedToServer = GeneratedColumn<bool>(
    'synced_to_server',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("synced_to_server" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _subscribedAtMeta = const VerificationMeta(
    'subscribedAt',
  );
  @override
  late final GeneratedColumn<int> subscribedAt = GeneratedColumn<int>(
    'subscribed_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    source,
    sourceId,
    mediaType,
    title,
    titleCn,
    posterUrl,
    platform,
    category,
    lastAirDate,
    status,
    syncedToServer,
    subscribedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'calendar_subscriptions';
  @override
  VerificationContext validateIntegrity(
    Insertable<CalendarSubscription> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    } else if (isInserting) {
      context.missing(_sourceMeta);
    }
    if (data.containsKey('source_id')) {
      context.handle(
        _sourceIdMeta,
        sourceId.isAcceptableOrUnknown(data['source_id']!, _sourceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_sourceIdMeta);
    }
    if (data.containsKey('media_type')) {
      context.handle(
        _mediaTypeMeta,
        mediaType.isAcceptableOrUnknown(data['media_type']!, _mediaTypeMeta),
      );
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('title_cn')) {
      context.handle(
        _titleCnMeta,
        titleCn.isAcceptableOrUnknown(data['title_cn']!, _titleCnMeta),
      );
    }
    if (data.containsKey('poster_url')) {
      context.handle(
        _posterUrlMeta,
        posterUrl.isAcceptableOrUnknown(data['poster_url']!, _posterUrlMeta),
      );
    }
    if (data.containsKey('platform')) {
      context.handle(
        _platformMeta,
        platform.isAcceptableOrUnknown(data['platform']!, _platformMeta),
      );
    }
    if (data.containsKey('category')) {
      context.handle(
        _categoryMeta,
        category.isAcceptableOrUnknown(data['category']!, _categoryMeta),
      );
    }
    if (data.containsKey('last_air_date')) {
      context.handle(
        _lastAirDateMeta,
        lastAirDate.isAcceptableOrUnknown(
          data['last_air_date']!,
          _lastAirDateMeta,
        ),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('synced_to_server')) {
      context.handle(
        _syncedToServerMeta,
        syncedToServer.isAcceptableOrUnknown(
          data['synced_to_server']!,
          _syncedToServerMeta,
        ),
      );
    }
    if (data.containsKey('subscribed_at')) {
      context.handle(
        _subscribedAtMeta,
        subscribedAt.isAcceptableOrUnknown(
          data['subscribed_at']!,
          _subscribedAtMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_subscribedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {source, sourceId, mediaType};
  @override
  CalendarSubscription map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CalendarSubscription(
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      )!,
      sourceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_id'],
      )!,
      mediaType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}media_type'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      titleCn: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title_cn'],
      )!,
      posterUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}poster_url'],
      )!,
      platform: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}platform'],
      )!,
      category: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}category'],
      )!,
      lastAirDate: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_air_date'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      syncedToServer: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}synced_to_server'],
      )!,
      subscribedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}subscribed_at'],
      )!,
    );
  }

  @override
  $CalendarSubscriptionsTable createAlias(String alias) {
    return $CalendarSubscriptionsTable(attachedDatabase, alias);
  }
}

class CalendarSubscription extends DataClass
    implements Insertable<CalendarSubscription> {
  /// 来源：`tmdb` / `bilibili` / `bangumi`。
  final String source;

  /// 该源内的 id。
  final String sourceId;

  /// 类型：`tv` / `movie`（TMDB 两个命名空间的判别位）。
  final String mediaType;

  /// 剧名（显示用）。
  final String title;

  /// 中文名（有则优先显示）。
  final String titleCn;

  /// 海报 URL（https；TMDB/B站都是 https，Bangumi 需升级）。
  final String posterUrl;

  /// 播放平台（中文，如"腾讯视频"）。
  final String platform;

  /// 类别：`anime` / `variety` / `series`。
  final String category;

  /// 最近一次已知的更新日（`yyyy-MM-dd`），用于排序与"还有几天"。
  final String lastAirDate;

  /// **状态**（`连载中` / `已完结`；未知时为空串）。
  ///
  /// ## 为什么落库（用户要求"已完结的显示已完结，连载中的显示连载中"）
  /// 与剧名/海报同理：订阅必须能**断网显示**。
  /// 现查的话断网时状态空白 ⇒ 用户看到一张没有状态的怪卡片。
  ///
  /// ⚠️ 存的是**中文结果**而不是 TMDB 原始值（`Returning Series`）：
  ///    映射规则一变，老数据不会自动跟随 —— 但那样只需重订一次，
  ///    而存原始值会让 UI 每次都要做映射（多一处可能漏的地方）。
  final String status;

  /// 「**是否在服务端收藏里出现过**」—— 双向同步的安全阀门。
  ///
  /// ## 用户要求
  /// > "emby 服务端中的我的收藏 = 我的追剧，我的追剧 = 收藏。**要互相同步**哇。"
  ///
  /// ## ⚠️ 为什么不能"服务端没有就删本地"
  /// 本地可能有"**库里没有**"的**外部订阅**（先订阅、等入库）——
  /// 那些在服务端**没有**对应收藏（订阅时库里没命中 ⇒ 按规则不写收藏）。
  /// 若按"服务端没有就删"，会把它们**全删掉**（正是上次 uninstall 的痛）。
  ///
  /// ## 判据
  /// | 服务端 | 本列 | 动作 |
  /// |---|---|---|
  /// | 有 | 任意 | upsert + 置 **true** |
  /// | 没有 | **true** | 用户在服务端**取消**了 ⇒ **删本地** |
  /// | 没有 | false | 外部订阅 ⇒ **保留** |
  final bool syncedToServer;

  /// 订阅时间（Unix 秒）。
  final int subscribedAt;
  const CalendarSubscription({
    required this.source,
    required this.sourceId,
    required this.mediaType,
    required this.title,
    required this.titleCn,
    required this.posterUrl,
    required this.platform,
    required this.category,
    required this.lastAirDate,
    required this.status,
    required this.syncedToServer,
    required this.subscribedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['source'] = Variable<String>(source);
    map['source_id'] = Variable<String>(sourceId);
    map['media_type'] = Variable<String>(mediaType);
    map['title'] = Variable<String>(title);
    map['title_cn'] = Variable<String>(titleCn);
    map['poster_url'] = Variable<String>(posterUrl);
    map['platform'] = Variable<String>(platform);
    map['category'] = Variable<String>(category);
    map['last_air_date'] = Variable<String>(lastAirDate);
    map['status'] = Variable<String>(status);
    map['synced_to_server'] = Variable<bool>(syncedToServer);
    map['subscribed_at'] = Variable<int>(subscribedAt);
    return map;
  }

  CalendarSubscriptionsCompanion toCompanion(bool nullToAbsent) {
    return CalendarSubscriptionsCompanion(
      source: Value(source),
      sourceId: Value(sourceId),
      mediaType: Value(mediaType),
      title: Value(title),
      titleCn: Value(titleCn),
      posterUrl: Value(posterUrl),
      platform: Value(platform),
      category: Value(category),
      lastAirDate: Value(lastAirDate),
      status: Value(status),
      syncedToServer: Value(syncedToServer),
      subscribedAt: Value(subscribedAt),
    );
  }

  factory CalendarSubscription.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CalendarSubscription(
      source: serializer.fromJson<String>(json['source']),
      sourceId: serializer.fromJson<String>(json['sourceId']),
      mediaType: serializer.fromJson<String>(json['mediaType']),
      title: serializer.fromJson<String>(json['title']),
      titleCn: serializer.fromJson<String>(json['titleCn']),
      posterUrl: serializer.fromJson<String>(json['posterUrl']),
      platform: serializer.fromJson<String>(json['platform']),
      category: serializer.fromJson<String>(json['category']),
      lastAirDate: serializer.fromJson<String>(json['lastAirDate']),
      status: serializer.fromJson<String>(json['status']),
      syncedToServer: serializer.fromJson<bool>(json['syncedToServer']),
      subscribedAt: serializer.fromJson<int>(json['subscribedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'source': serializer.toJson<String>(source),
      'sourceId': serializer.toJson<String>(sourceId),
      'mediaType': serializer.toJson<String>(mediaType),
      'title': serializer.toJson<String>(title),
      'titleCn': serializer.toJson<String>(titleCn),
      'posterUrl': serializer.toJson<String>(posterUrl),
      'platform': serializer.toJson<String>(platform),
      'category': serializer.toJson<String>(category),
      'lastAirDate': serializer.toJson<String>(lastAirDate),
      'status': serializer.toJson<String>(status),
      'syncedToServer': serializer.toJson<bool>(syncedToServer),
      'subscribedAt': serializer.toJson<int>(subscribedAt),
    };
  }

  CalendarSubscription copyWith({
    String? source,
    String? sourceId,
    String? mediaType,
    String? title,
    String? titleCn,
    String? posterUrl,
    String? platform,
    String? category,
    String? lastAirDate,
    String? status,
    bool? syncedToServer,
    int? subscribedAt,
  }) => CalendarSubscription(
    source: source ?? this.source,
    sourceId: sourceId ?? this.sourceId,
    mediaType: mediaType ?? this.mediaType,
    title: title ?? this.title,
    titleCn: titleCn ?? this.titleCn,
    posterUrl: posterUrl ?? this.posterUrl,
    platform: platform ?? this.platform,
    category: category ?? this.category,
    lastAirDate: lastAirDate ?? this.lastAirDate,
    status: status ?? this.status,
    syncedToServer: syncedToServer ?? this.syncedToServer,
    subscribedAt: subscribedAt ?? this.subscribedAt,
  );
  CalendarSubscription copyWithCompanion(CalendarSubscriptionsCompanion data) {
    return CalendarSubscription(
      source: data.source.present ? data.source.value : this.source,
      sourceId: data.sourceId.present ? data.sourceId.value : this.sourceId,
      mediaType: data.mediaType.present ? data.mediaType.value : this.mediaType,
      title: data.title.present ? data.title.value : this.title,
      titleCn: data.titleCn.present ? data.titleCn.value : this.titleCn,
      posterUrl: data.posterUrl.present ? data.posterUrl.value : this.posterUrl,
      platform: data.platform.present ? data.platform.value : this.platform,
      category: data.category.present ? data.category.value : this.category,
      lastAirDate: data.lastAirDate.present
          ? data.lastAirDate.value
          : this.lastAirDate,
      status: data.status.present ? data.status.value : this.status,
      syncedToServer: data.syncedToServer.present
          ? data.syncedToServer.value
          : this.syncedToServer,
      subscribedAt: data.subscribedAt.present
          ? data.subscribedAt.value
          : this.subscribedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CalendarSubscription(')
          ..write('source: $source, ')
          ..write('sourceId: $sourceId, ')
          ..write('mediaType: $mediaType, ')
          ..write('title: $title, ')
          ..write('titleCn: $titleCn, ')
          ..write('posterUrl: $posterUrl, ')
          ..write('platform: $platform, ')
          ..write('category: $category, ')
          ..write('lastAirDate: $lastAirDate, ')
          ..write('status: $status, ')
          ..write('syncedToServer: $syncedToServer, ')
          ..write('subscribedAt: $subscribedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    source,
    sourceId,
    mediaType,
    title,
    titleCn,
    posterUrl,
    platform,
    category,
    lastAirDate,
    status,
    syncedToServer,
    subscribedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CalendarSubscription &&
          other.source == this.source &&
          other.sourceId == this.sourceId &&
          other.mediaType == this.mediaType &&
          other.title == this.title &&
          other.titleCn == this.titleCn &&
          other.posterUrl == this.posterUrl &&
          other.platform == this.platform &&
          other.category == this.category &&
          other.lastAirDate == this.lastAirDate &&
          other.status == this.status &&
          other.syncedToServer == this.syncedToServer &&
          other.subscribedAt == this.subscribedAt);
}

class CalendarSubscriptionsCompanion
    extends UpdateCompanion<CalendarSubscription> {
  final Value<String> source;
  final Value<String> sourceId;
  final Value<String> mediaType;
  final Value<String> title;
  final Value<String> titleCn;
  final Value<String> posterUrl;
  final Value<String> platform;
  final Value<String> category;
  final Value<String> lastAirDate;
  final Value<String> status;
  final Value<bool> syncedToServer;
  final Value<int> subscribedAt;
  final Value<int> rowid;
  const CalendarSubscriptionsCompanion({
    this.source = const Value.absent(),
    this.sourceId = const Value.absent(),
    this.mediaType = const Value.absent(),
    this.title = const Value.absent(),
    this.titleCn = const Value.absent(),
    this.posterUrl = const Value.absent(),
    this.platform = const Value.absent(),
    this.category = const Value.absent(),
    this.lastAirDate = const Value.absent(),
    this.status = const Value.absent(),
    this.syncedToServer = const Value.absent(),
    this.subscribedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CalendarSubscriptionsCompanion.insert({
    required String source,
    required String sourceId,
    this.mediaType = const Value.absent(),
    required String title,
    this.titleCn = const Value.absent(),
    this.posterUrl = const Value.absent(),
    this.platform = const Value.absent(),
    this.category = const Value.absent(),
    this.lastAirDate = const Value.absent(),
    this.status = const Value.absent(),
    this.syncedToServer = const Value.absent(),
    required int subscribedAt,
    this.rowid = const Value.absent(),
  }) : source = Value(source),
       sourceId = Value(sourceId),
       title = Value(title),
       subscribedAt = Value(subscribedAt);
  static Insertable<CalendarSubscription> custom({
    Expression<String>? source,
    Expression<String>? sourceId,
    Expression<String>? mediaType,
    Expression<String>? title,
    Expression<String>? titleCn,
    Expression<String>? posterUrl,
    Expression<String>? platform,
    Expression<String>? category,
    Expression<String>? lastAirDate,
    Expression<String>? status,
    Expression<bool>? syncedToServer,
    Expression<int>? subscribedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (source != null) 'source': source,
      if (sourceId != null) 'source_id': sourceId,
      if (mediaType != null) 'media_type': mediaType,
      if (title != null) 'title': title,
      if (titleCn != null) 'title_cn': titleCn,
      if (posterUrl != null) 'poster_url': posterUrl,
      if (platform != null) 'platform': platform,
      if (category != null) 'category': category,
      if (lastAirDate != null) 'last_air_date': lastAirDate,
      if (status != null) 'status': status,
      if (syncedToServer != null) 'synced_to_server': syncedToServer,
      if (subscribedAt != null) 'subscribed_at': subscribedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CalendarSubscriptionsCompanion copyWith({
    Value<String>? source,
    Value<String>? sourceId,
    Value<String>? mediaType,
    Value<String>? title,
    Value<String>? titleCn,
    Value<String>? posterUrl,
    Value<String>? platform,
    Value<String>? category,
    Value<String>? lastAirDate,
    Value<String>? status,
    Value<bool>? syncedToServer,
    Value<int>? subscribedAt,
    Value<int>? rowid,
  }) {
    return CalendarSubscriptionsCompanion(
      source: source ?? this.source,
      sourceId: sourceId ?? this.sourceId,
      mediaType: mediaType ?? this.mediaType,
      title: title ?? this.title,
      titleCn: titleCn ?? this.titleCn,
      posterUrl: posterUrl ?? this.posterUrl,
      platform: platform ?? this.platform,
      category: category ?? this.category,
      lastAirDate: lastAirDate ?? this.lastAirDate,
      status: status ?? this.status,
      syncedToServer: syncedToServer ?? this.syncedToServer,
      subscribedAt: subscribedAt ?? this.subscribedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (sourceId.present) {
      map['source_id'] = Variable<String>(sourceId.value);
    }
    if (mediaType.present) {
      map['media_type'] = Variable<String>(mediaType.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (titleCn.present) {
      map['title_cn'] = Variable<String>(titleCn.value);
    }
    if (posterUrl.present) {
      map['poster_url'] = Variable<String>(posterUrl.value);
    }
    if (platform.present) {
      map['platform'] = Variable<String>(platform.value);
    }
    if (category.present) {
      map['category'] = Variable<String>(category.value);
    }
    if (lastAirDate.present) {
      map['last_air_date'] = Variable<String>(lastAirDate.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (syncedToServer.present) {
      map['synced_to_server'] = Variable<bool>(syncedToServer.value);
    }
    if (subscribedAt.present) {
      map['subscribed_at'] = Variable<int>(subscribedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CalendarSubscriptionsCompanion(')
          ..write('source: $source, ')
          ..write('sourceId: $sourceId, ')
          ..write('mediaType: $mediaType, ')
          ..write('title: $title, ')
          ..write('titleCn: $titleCn, ')
          ..write('posterUrl: $posterUrl, ')
          ..write('platform: $platform, ')
          ..write('category: $category, ')
          ..write('lastAirDate: $lastAirDate, ')
          ..write('status: $status, ')
          ..write('syncedToServer: $syncedToServer, ')
          ..write('subscribedAt: $subscribedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AnimeTimelinesTable extends AnimeTimelines
    with TableInfo<$AnimeTimelinesTable, AnimeTimeline> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AnimeTimelinesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _platformMeta = const VerificationMeta(
    'platform',
  );
  @override
  late final GeneratedColumn<String> platform = GeneratedColumn<String>(
    'platform',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('bilibili'),
  );
  static const VerificationMeta _weekdayMeta = const VerificationMeta(
    'weekday',
  );
  @override
  late final GeneratedColumn<int> weekday = GeneratedColumn<int>(
    'weekday',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _airTimeMeta = const VerificationMeta(
    'airTime',
  );
  @override
  late final GeneratedColumn<String> airTime = GeneratedColumn<String>(
    'air_time',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _sourceIdMeta = const VerificationMeta(
    'sourceId',
  );
  @override
  late final GeneratedColumn<String> sourceId = GeneratedColumn<String>(
    'source_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    title,
    platform,
    weekday,
    airTime,
    sourceId,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'anime_timelines';
  @override
  VerificationContext validateIntegrity(
    Insertable<AnimeTimeline> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('platform')) {
      context.handle(
        _platformMeta,
        platform.isAcceptableOrUnknown(data['platform']!, _platformMeta),
      );
    }
    if (data.containsKey('weekday')) {
      context.handle(
        _weekdayMeta,
        weekday.isAcceptableOrUnknown(data['weekday']!, _weekdayMeta),
      );
    } else if (isInserting) {
      context.missing(_weekdayMeta);
    }
    if (data.containsKey('air_time')) {
      context.handle(
        _airTimeMeta,
        airTime.isAcceptableOrUnknown(data['air_time']!, _airTimeMeta),
      );
    }
    if (data.containsKey('source_id')) {
      context.handle(
        _sourceIdMeta,
        sourceId.isAcceptableOrUnknown(data['source_id']!, _sourceIdMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {title, platform};
  @override
  AnimeTimeline map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AnimeTimeline(
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      platform: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}platform'],
      )!,
      weekday: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}weekday'],
      )!,
      airTime: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}air_time'],
      )!,
      sourceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_id'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $AnimeTimelinesTable createAlias(String alias) {
    return $AnimeTimelinesTable(attachedDatabase, alias);
  }
}

class AnimeTimeline extends DataClass implements Insertable<AnimeTimeline> {
  /// 剧名（B站原文；匹配订阅时用）。
  final String title;

  /// 平台（当前只有 `bilibili`）。
  final String platform;

  /// 周几（1=周一 … 7=周日）。
  final int weekday;

  /// 更新时刻（`HH:mm`）。
  final String airTime;

  /// 源内 id（B站 `season_id`，可用于跳转）。
  final String sourceId;

  /// 索引时间（毫秒；用于 TTL 判断 —— 时刻极少变，可长缓存）。
  final int updatedAt;
  const AnimeTimeline({
    required this.title,
    required this.platform,
    required this.weekday,
    required this.airTime,
    required this.sourceId,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['title'] = Variable<String>(title);
    map['platform'] = Variable<String>(platform);
    map['weekday'] = Variable<int>(weekday);
    map['air_time'] = Variable<String>(airTime);
    map['source_id'] = Variable<String>(sourceId);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  AnimeTimelinesCompanion toCompanion(bool nullToAbsent) {
    return AnimeTimelinesCompanion(
      title: Value(title),
      platform: Value(platform),
      weekday: Value(weekday),
      airTime: Value(airTime),
      sourceId: Value(sourceId),
      updatedAt: Value(updatedAt),
    );
  }

  factory AnimeTimeline.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AnimeTimeline(
      title: serializer.fromJson<String>(json['title']),
      platform: serializer.fromJson<String>(json['platform']),
      weekday: serializer.fromJson<int>(json['weekday']),
      airTime: serializer.fromJson<String>(json['airTime']),
      sourceId: serializer.fromJson<String>(json['sourceId']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'title': serializer.toJson<String>(title),
      'platform': serializer.toJson<String>(platform),
      'weekday': serializer.toJson<int>(weekday),
      'airTime': serializer.toJson<String>(airTime),
      'sourceId': serializer.toJson<String>(sourceId),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  AnimeTimeline copyWith({
    String? title,
    String? platform,
    int? weekday,
    String? airTime,
    String? sourceId,
    int? updatedAt,
  }) => AnimeTimeline(
    title: title ?? this.title,
    platform: platform ?? this.platform,
    weekday: weekday ?? this.weekday,
    airTime: airTime ?? this.airTime,
    sourceId: sourceId ?? this.sourceId,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  AnimeTimeline copyWithCompanion(AnimeTimelinesCompanion data) {
    return AnimeTimeline(
      title: data.title.present ? data.title.value : this.title,
      platform: data.platform.present ? data.platform.value : this.platform,
      weekday: data.weekday.present ? data.weekday.value : this.weekday,
      airTime: data.airTime.present ? data.airTime.value : this.airTime,
      sourceId: data.sourceId.present ? data.sourceId.value : this.sourceId,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AnimeTimeline(')
          ..write('title: $title, ')
          ..write('platform: $platform, ')
          ..write('weekday: $weekday, ')
          ..write('airTime: $airTime, ')
          ..write('sourceId: $sourceId, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(title, platform, weekday, airTime, sourceId, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AnimeTimeline &&
          other.title == this.title &&
          other.platform == this.platform &&
          other.weekday == this.weekday &&
          other.airTime == this.airTime &&
          other.sourceId == this.sourceId &&
          other.updatedAt == this.updatedAt);
}

class AnimeTimelinesCompanion extends UpdateCompanion<AnimeTimeline> {
  final Value<String> title;
  final Value<String> platform;
  final Value<int> weekday;
  final Value<String> airTime;
  final Value<String> sourceId;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const AnimeTimelinesCompanion({
    this.title = const Value.absent(),
    this.platform = const Value.absent(),
    this.weekday = const Value.absent(),
    this.airTime = const Value.absent(),
    this.sourceId = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AnimeTimelinesCompanion.insert({
    required String title,
    this.platform = const Value.absent(),
    required int weekday,
    this.airTime = const Value.absent(),
    this.sourceId = const Value.absent(),
    required int updatedAt,
    this.rowid = const Value.absent(),
  }) : title = Value(title),
       weekday = Value(weekday),
       updatedAt = Value(updatedAt);
  static Insertable<AnimeTimeline> custom({
    Expression<String>? title,
    Expression<String>? platform,
    Expression<int>? weekday,
    Expression<String>? airTime,
    Expression<String>? sourceId,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (title != null) 'title': title,
      if (platform != null) 'platform': platform,
      if (weekday != null) 'weekday': weekday,
      if (airTime != null) 'air_time': airTime,
      if (sourceId != null) 'source_id': sourceId,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AnimeTimelinesCompanion copyWith({
    Value<String>? title,
    Value<String>? platform,
    Value<int>? weekday,
    Value<String>? airTime,
    Value<String>? sourceId,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return AnimeTimelinesCompanion(
      title: title ?? this.title,
      platform: platform ?? this.platform,
      weekday: weekday ?? this.weekday,
      airTime: airTime ?? this.airTime,
      sourceId: sourceId ?? this.sourceId,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (platform.present) {
      map['platform'] = Variable<String>(platform.value);
    }
    if (weekday.present) {
      map['weekday'] = Variable<int>(weekday.value);
    }
    if (airTime.present) {
      map['air_time'] = Variable<String>(airTime.value);
    }
    if (sourceId.present) {
      map['source_id'] = Variable<String>(sourceId.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AnimeTimelinesCompanion(')
          ..write('title: $title, ')
          ..write('platform: $platform, ')
          ..write('weekday: $weekday, ')
          ..write('airTime: $airTime, ')
          ..write('sourceId: $sourceId, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $DoubanCachesTable doubanCaches = $DoubanCachesTable(this);
  late final $PlayHistoriesTable playHistories = $PlayHistoriesTable(this);
  late final $CalendarSubscriptionsTable calendarSubscriptions =
      $CalendarSubscriptionsTable(this);
  late final $AnimeTimelinesTable animeTimelines = $AnimeTimelinesTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    doubanCaches,
    playHistories,
    calendarSubscriptions,
    animeTimelines,
  ];
}

typedef $$DoubanCachesTableCreateCompanionBuilder =
    DoubanCachesCompanion Function({
      required String key,
      required String value,
      required int expiresAt,
      required int savedAt,
      Value<int> rowid,
    });
typedef $$DoubanCachesTableUpdateCompanionBuilder =
    DoubanCachesCompanion Function({
      Value<String> key,
      Value<String> value,
      Value<int> expiresAt,
      Value<int> savedAt,
      Value<int> rowid,
    });

class $$DoubanCachesTableFilterComposer
    extends Composer<_$AppDatabase, $DoubanCachesTable> {
  $$DoubanCachesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get expiresAt => $composableBuilder(
    column: $table.expiresAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get savedAt => $composableBuilder(
    column: $table.savedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$DoubanCachesTableOrderingComposer
    extends Composer<_$AppDatabase, $DoubanCachesTable> {
  $$DoubanCachesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get expiresAt => $composableBuilder(
    column: $table.expiresAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get savedAt => $composableBuilder(
    column: $table.savedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$DoubanCachesTableAnnotationComposer
    extends Composer<_$AppDatabase, $DoubanCachesTable> {
  $$DoubanCachesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);

  GeneratedColumn<int> get expiresAt =>
      $composableBuilder(column: $table.expiresAt, builder: (column) => column);

  GeneratedColumn<int> get savedAt =>
      $composableBuilder(column: $table.savedAt, builder: (column) => column);
}

class $$DoubanCachesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $DoubanCachesTable,
          DoubanCache,
          $$DoubanCachesTableFilterComposer,
          $$DoubanCachesTableOrderingComposer,
          $$DoubanCachesTableAnnotationComposer,
          $$DoubanCachesTableCreateCompanionBuilder,
          $$DoubanCachesTableUpdateCompanionBuilder,
          (
            DoubanCache,
            BaseReferences<_$AppDatabase, $DoubanCachesTable, DoubanCache>,
          ),
          DoubanCache,
          PrefetchHooks Function()
        > {
  $$DoubanCachesTableTableManager(_$AppDatabase db, $DoubanCachesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DoubanCachesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DoubanCachesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DoubanCachesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> key = const Value.absent(),
                Value<String> value = const Value.absent(),
                Value<int> expiresAt = const Value.absent(),
                Value<int> savedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => DoubanCachesCompanion(
                key: key,
                value: value,
                expiresAt: expiresAt,
                savedAt: savedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String key,
                required String value,
                required int expiresAt,
                required int savedAt,
                Value<int> rowid = const Value.absent(),
              }) => DoubanCachesCompanion.insert(
                key: key,
                value: value,
                expiresAt: expiresAt,
                savedAt: savedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$DoubanCachesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $DoubanCachesTable,
      DoubanCache,
      $$DoubanCachesTableFilterComposer,
      $$DoubanCachesTableOrderingComposer,
      $$DoubanCachesTableAnnotationComposer,
      $$DoubanCachesTableCreateCompanionBuilder,
      $$DoubanCachesTableUpdateCompanionBuilder,
      (
        DoubanCache,
        BaseReferences<_$AppDatabase, $DoubanCachesTable, DoubanCache>,
      ),
      DoubanCache,
      PrefetchHooks Function()
    >;
typedef $$PlayHistoriesTableCreateCompanionBuilder =
    PlayHistoriesCompanion Function({
      required String itemId,
      Value<String> name,
      Value<String> type,
      Value<int> positionTicks,
      Value<int> runtimeTicks,
      required int playedAt,
      Value<int> rowid,
    });
typedef $$PlayHistoriesTableUpdateCompanionBuilder =
    PlayHistoriesCompanion Function({
      Value<String> itemId,
      Value<String> name,
      Value<String> type,
      Value<int> positionTicks,
      Value<int> runtimeTicks,
      Value<int> playedAt,
      Value<int> rowid,
    });

class $$PlayHistoriesTableFilterComposer
    extends Composer<_$AppDatabase, $PlayHistoriesTable> {
  $$PlayHistoriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get itemId => $composableBuilder(
    column: $table.itemId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get positionTicks => $composableBuilder(
    column: $table.positionTicks,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get runtimeTicks => $composableBuilder(
    column: $table.runtimeTicks,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get playedAt => $composableBuilder(
    column: $table.playedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$PlayHistoriesTableOrderingComposer
    extends Composer<_$AppDatabase, $PlayHistoriesTable> {
  $$PlayHistoriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get itemId => $composableBuilder(
    column: $table.itemId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get positionTicks => $composableBuilder(
    column: $table.positionTicks,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get runtimeTicks => $composableBuilder(
    column: $table.runtimeTicks,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get playedAt => $composableBuilder(
    column: $table.playedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$PlayHistoriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $PlayHistoriesTable> {
  $$PlayHistoriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get itemId =>
      $composableBuilder(column: $table.itemId, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<int> get positionTicks => $composableBuilder(
    column: $table.positionTicks,
    builder: (column) => column,
  );

  GeneratedColumn<int> get runtimeTicks => $composableBuilder(
    column: $table.runtimeTicks,
    builder: (column) => column,
  );

  GeneratedColumn<int> get playedAt =>
      $composableBuilder(column: $table.playedAt, builder: (column) => column);
}

class $$PlayHistoriesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $PlayHistoriesTable,
          PlayHistory,
          $$PlayHistoriesTableFilterComposer,
          $$PlayHistoriesTableOrderingComposer,
          $$PlayHistoriesTableAnnotationComposer,
          $$PlayHistoriesTableCreateCompanionBuilder,
          $$PlayHistoriesTableUpdateCompanionBuilder,
          (
            PlayHistory,
            BaseReferences<_$AppDatabase, $PlayHistoriesTable, PlayHistory>,
          ),
          PlayHistory,
          PrefetchHooks Function()
        > {
  $$PlayHistoriesTableTableManager(_$AppDatabase db, $PlayHistoriesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PlayHistoriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PlayHistoriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PlayHistoriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> itemId = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> type = const Value.absent(),
                Value<int> positionTicks = const Value.absent(),
                Value<int> runtimeTicks = const Value.absent(),
                Value<int> playedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PlayHistoriesCompanion(
                itemId: itemId,
                name: name,
                type: type,
                positionTicks: positionTicks,
                runtimeTicks: runtimeTicks,
                playedAt: playedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String itemId,
                Value<String> name = const Value.absent(),
                Value<String> type = const Value.absent(),
                Value<int> positionTicks = const Value.absent(),
                Value<int> runtimeTicks = const Value.absent(),
                required int playedAt,
                Value<int> rowid = const Value.absent(),
              }) => PlayHistoriesCompanion.insert(
                itemId: itemId,
                name: name,
                type: type,
                positionTicks: positionTicks,
                runtimeTicks: runtimeTicks,
                playedAt: playedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$PlayHistoriesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $PlayHistoriesTable,
      PlayHistory,
      $$PlayHistoriesTableFilterComposer,
      $$PlayHistoriesTableOrderingComposer,
      $$PlayHistoriesTableAnnotationComposer,
      $$PlayHistoriesTableCreateCompanionBuilder,
      $$PlayHistoriesTableUpdateCompanionBuilder,
      (
        PlayHistory,
        BaseReferences<_$AppDatabase, $PlayHistoriesTable, PlayHistory>,
      ),
      PlayHistory,
      PrefetchHooks Function()
    >;
typedef $$CalendarSubscriptionsTableCreateCompanionBuilder =
    CalendarSubscriptionsCompanion Function({
      required String source,
      required String sourceId,
      Value<String> mediaType,
      required String title,
      Value<String> titleCn,
      Value<String> posterUrl,
      Value<String> platform,
      Value<String> category,
      Value<String> lastAirDate,
      Value<String> status,
      Value<bool> syncedToServer,
      required int subscribedAt,
      Value<int> rowid,
    });
typedef $$CalendarSubscriptionsTableUpdateCompanionBuilder =
    CalendarSubscriptionsCompanion Function({
      Value<String> source,
      Value<String> sourceId,
      Value<String> mediaType,
      Value<String> title,
      Value<String> titleCn,
      Value<String> posterUrl,
      Value<String> platform,
      Value<String> category,
      Value<String> lastAirDate,
      Value<String> status,
      Value<bool> syncedToServer,
      Value<int> subscribedAt,
      Value<int> rowid,
    });

class $$CalendarSubscriptionsTableFilterComposer
    extends Composer<_$AppDatabase, $CalendarSubscriptionsTable> {
  $$CalendarSubscriptionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourceId => $composableBuilder(
    column: $table.sourceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mediaType => $composableBuilder(
    column: $table.mediaType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get titleCn => $composableBuilder(
    column: $table.titleCn,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get posterUrl => $composableBuilder(
    column: $table.posterUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get platform => $composableBuilder(
    column: $table.platform,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get category => $composableBuilder(
    column: $table.category,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastAirDate => $composableBuilder(
    column: $table.lastAirDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get syncedToServer => $composableBuilder(
    column: $table.syncedToServer,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get subscribedAt => $composableBuilder(
    column: $table.subscribedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CalendarSubscriptionsTableOrderingComposer
    extends Composer<_$AppDatabase, $CalendarSubscriptionsTable> {
  $$CalendarSubscriptionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceId => $composableBuilder(
    column: $table.sourceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mediaType => $composableBuilder(
    column: $table.mediaType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get titleCn => $composableBuilder(
    column: $table.titleCn,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get posterUrl => $composableBuilder(
    column: $table.posterUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get platform => $composableBuilder(
    column: $table.platform,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get category => $composableBuilder(
    column: $table.category,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastAirDate => $composableBuilder(
    column: $table.lastAirDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get syncedToServer => $composableBuilder(
    column: $table.syncedToServer,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get subscribedAt => $composableBuilder(
    column: $table.subscribedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CalendarSubscriptionsTableAnnotationComposer
    extends Composer<_$AppDatabase, $CalendarSubscriptionsTable> {
  $$CalendarSubscriptionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<String> get sourceId =>
      $composableBuilder(column: $table.sourceId, builder: (column) => column);

  GeneratedColumn<String> get mediaType =>
      $composableBuilder(column: $table.mediaType, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get titleCn =>
      $composableBuilder(column: $table.titleCn, builder: (column) => column);

  GeneratedColumn<String> get posterUrl =>
      $composableBuilder(column: $table.posterUrl, builder: (column) => column);

  GeneratedColumn<String> get platform =>
      $composableBuilder(column: $table.platform, builder: (column) => column);

  GeneratedColumn<String> get category =>
      $composableBuilder(column: $table.category, builder: (column) => column);

  GeneratedColumn<String> get lastAirDate => $composableBuilder(
    column: $table.lastAirDate,
    builder: (column) => column,
  );

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<bool> get syncedToServer => $composableBuilder(
    column: $table.syncedToServer,
    builder: (column) => column,
  );

  GeneratedColumn<int> get subscribedAt => $composableBuilder(
    column: $table.subscribedAt,
    builder: (column) => column,
  );
}

class $$CalendarSubscriptionsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $CalendarSubscriptionsTable,
          CalendarSubscription,
          $$CalendarSubscriptionsTableFilterComposer,
          $$CalendarSubscriptionsTableOrderingComposer,
          $$CalendarSubscriptionsTableAnnotationComposer,
          $$CalendarSubscriptionsTableCreateCompanionBuilder,
          $$CalendarSubscriptionsTableUpdateCompanionBuilder,
          (
            CalendarSubscription,
            BaseReferences<
              _$AppDatabase,
              $CalendarSubscriptionsTable,
              CalendarSubscription
            >,
          ),
          CalendarSubscription,
          PrefetchHooks Function()
        > {
  $$CalendarSubscriptionsTableTableManager(
    _$AppDatabase db,
    $CalendarSubscriptionsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CalendarSubscriptionsTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$CalendarSubscriptionsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$CalendarSubscriptionsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> source = const Value.absent(),
                Value<String> sourceId = const Value.absent(),
                Value<String> mediaType = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> titleCn = const Value.absent(),
                Value<String> posterUrl = const Value.absent(),
                Value<String> platform = const Value.absent(),
                Value<String> category = const Value.absent(),
                Value<String> lastAirDate = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<bool> syncedToServer = const Value.absent(),
                Value<int> subscribedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CalendarSubscriptionsCompanion(
                source: source,
                sourceId: sourceId,
                mediaType: mediaType,
                title: title,
                titleCn: titleCn,
                posterUrl: posterUrl,
                platform: platform,
                category: category,
                lastAirDate: lastAirDate,
                status: status,
                syncedToServer: syncedToServer,
                subscribedAt: subscribedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String source,
                required String sourceId,
                Value<String> mediaType = const Value.absent(),
                required String title,
                Value<String> titleCn = const Value.absent(),
                Value<String> posterUrl = const Value.absent(),
                Value<String> platform = const Value.absent(),
                Value<String> category = const Value.absent(),
                Value<String> lastAirDate = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<bool> syncedToServer = const Value.absent(),
                required int subscribedAt,
                Value<int> rowid = const Value.absent(),
              }) => CalendarSubscriptionsCompanion.insert(
                source: source,
                sourceId: sourceId,
                mediaType: mediaType,
                title: title,
                titleCn: titleCn,
                posterUrl: posterUrl,
                platform: platform,
                category: category,
                lastAirDate: lastAirDate,
                status: status,
                syncedToServer: syncedToServer,
                subscribedAt: subscribedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CalendarSubscriptionsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $CalendarSubscriptionsTable,
      CalendarSubscription,
      $$CalendarSubscriptionsTableFilterComposer,
      $$CalendarSubscriptionsTableOrderingComposer,
      $$CalendarSubscriptionsTableAnnotationComposer,
      $$CalendarSubscriptionsTableCreateCompanionBuilder,
      $$CalendarSubscriptionsTableUpdateCompanionBuilder,
      (
        CalendarSubscription,
        BaseReferences<
          _$AppDatabase,
          $CalendarSubscriptionsTable,
          CalendarSubscription
        >,
      ),
      CalendarSubscription,
      PrefetchHooks Function()
    >;
typedef $$AnimeTimelinesTableCreateCompanionBuilder =
    AnimeTimelinesCompanion Function({
      required String title,
      Value<String> platform,
      required int weekday,
      Value<String> airTime,
      Value<String> sourceId,
      required int updatedAt,
      Value<int> rowid,
    });
typedef $$AnimeTimelinesTableUpdateCompanionBuilder =
    AnimeTimelinesCompanion Function({
      Value<String> title,
      Value<String> platform,
      Value<int> weekday,
      Value<String> airTime,
      Value<String> sourceId,
      Value<int> updatedAt,
      Value<int> rowid,
    });

class $$AnimeTimelinesTableFilterComposer
    extends Composer<_$AppDatabase, $AnimeTimelinesTable> {
  $$AnimeTimelinesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get platform => $composableBuilder(
    column: $table.platform,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get weekday => $composableBuilder(
    column: $table.weekday,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get airTime => $composableBuilder(
    column: $table.airTime,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourceId => $composableBuilder(
    column: $table.sourceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AnimeTimelinesTableOrderingComposer
    extends Composer<_$AppDatabase, $AnimeTimelinesTable> {
  $$AnimeTimelinesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get platform => $composableBuilder(
    column: $table.platform,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get weekday => $composableBuilder(
    column: $table.weekday,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get airTime => $composableBuilder(
    column: $table.airTime,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceId => $composableBuilder(
    column: $table.sourceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AnimeTimelinesTableAnnotationComposer
    extends Composer<_$AppDatabase, $AnimeTimelinesTable> {
  $$AnimeTimelinesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get platform =>
      $composableBuilder(column: $table.platform, builder: (column) => column);

  GeneratedColumn<int> get weekday =>
      $composableBuilder(column: $table.weekday, builder: (column) => column);

  GeneratedColumn<String> get airTime =>
      $composableBuilder(column: $table.airTime, builder: (column) => column);

  GeneratedColumn<String> get sourceId =>
      $composableBuilder(column: $table.sourceId, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$AnimeTimelinesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AnimeTimelinesTable,
          AnimeTimeline,
          $$AnimeTimelinesTableFilterComposer,
          $$AnimeTimelinesTableOrderingComposer,
          $$AnimeTimelinesTableAnnotationComposer,
          $$AnimeTimelinesTableCreateCompanionBuilder,
          $$AnimeTimelinesTableUpdateCompanionBuilder,
          (
            AnimeTimeline,
            BaseReferences<_$AppDatabase, $AnimeTimelinesTable, AnimeTimeline>,
          ),
          AnimeTimeline,
          PrefetchHooks Function()
        > {
  $$AnimeTimelinesTableTableManager(
    _$AppDatabase db,
    $AnimeTimelinesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AnimeTimelinesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AnimeTimelinesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AnimeTimelinesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> title = const Value.absent(),
                Value<String> platform = const Value.absent(),
                Value<int> weekday = const Value.absent(),
                Value<String> airTime = const Value.absent(),
                Value<String> sourceId = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AnimeTimelinesCompanion(
                title: title,
                platform: platform,
                weekday: weekday,
                airTime: airTime,
                sourceId: sourceId,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String title,
                Value<String> platform = const Value.absent(),
                required int weekday,
                Value<String> airTime = const Value.absent(),
                Value<String> sourceId = const Value.absent(),
                required int updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => AnimeTimelinesCompanion.insert(
                title: title,
                platform: platform,
                weekday: weekday,
                airTime: airTime,
                sourceId: sourceId,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AnimeTimelinesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AnimeTimelinesTable,
      AnimeTimeline,
      $$AnimeTimelinesTableFilterComposer,
      $$AnimeTimelinesTableOrderingComposer,
      $$AnimeTimelinesTableAnnotationComposer,
      $$AnimeTimelinesTableCreateCompanionBuilder,
      $$AnimeTimelinesTableUpdateCompanionBuilder,
      (
        AnimeTimeline,
        BaseReferences<_$AppDatabase, $AnimeTimelinesTable, AnimeTimeline>,
      ),
      AnimeTimeline,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$DoubanCachesTableTableManager get doubanCaches =>
      $$DoubanCachesTableTableManager(_db, _db.doubanCaches);
  $$PlayHistoriesTableTableManager get playHistories =>
      $$PlayHistoriesTableTableManager(_db, _db.playHistories);
  $$CalendarSubscriptionsTableTableManager get calendarSubscriptions =>
      $$CalendarSubscriptionsTableTableManager(_db, _db.calendarSubscriptions);
  $$AnimeTimelinesTableTableManager get animeTimelines =>
      $$AnimeTimelinesTableTableManager(_db, _db.animeTimelines);
}
