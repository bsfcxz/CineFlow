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

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $DoubanCachesTable doubanCaches = $DoubanCachesTable(this);
  late final $PlayHistoriesTable playHistories = $PlayHistoriesTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    doubanCaches,
    playHistories,
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

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$DoubanCachesTableTableManager get doubanCaches =>
      $$DoubanCachesTableTableManager(_db, _db.doubanCaches);
  $$PlayHistoriesTableTableManager get playHistories =>
      $$PlayHistoriesTableTableManager(_db, _db.playHistories);
}
