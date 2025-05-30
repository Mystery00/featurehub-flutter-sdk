import 'dart:async';
import 'dart:convert';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_client_sdk/featurehub.dart';
import 'package:logging/logging.dart';
import 'package:rxdart/rxdart.dart';

enum Readyness { NotReady, Ready, Failed }

abstract class FeatureStateHolder {
  bool get exists;
  bool? get booleanValue;
  String? get stringValue;
  num? get numberValue;
  String? get key;
  dynamic get jsonValue;
  FeatureValueType? get type;

  dynamic get value;

  int? get version;

  Stream<FeatureStateHolder> get featureUpdateStream;

  bool get isSet;
  bool get isEnabled;
  FeatureStateHolder copy();
}

class ValueMatch {
  final bool matched;
  final String? value;

  ValueMatch(this.matched, this.value);
}

class _InterceptorHolder {
  final bool allowLockOverride;
  final FeatureValueInterceptor interceptor;

  _InterceptorHolder(this.allowLockOverride, this.interceptor);
}

typedef FeatureValueInterceptor = ValueMatch Function(String? key);

class AnalyticsEvent {
  final String action;
  final Map<String, Object>? other;
  final List<FeatureStateHolder> features;

  AnalyticsEvent(this.action, this.features, this.other);
}

class _FeatureStateBaseHolder implements FeatureStateHolder {
  dynamic _value;
  FeatureState? _featureState;
  BehaviorSubject<FeatureStateHolder>? _listeners;
  final List<_InterceptorHolder> featureValueInterceptors;

  @override
  String? get key => _featureState?.key;
  @override
  Stream<FeatureStateHolder> get featureUpdateStream => _listeners!.stream;

  _FeatureStateBaseHolder(
      _FeatureStateBaseHolder? fs, this.featureValueInterceptors) {
    _listeners = fs?._listeners ?? BehaviorSubject<FeatureStateHolder>();
  }

  @override
  dynamic get value => _value;

  bool get isSet => _value != null;

  bool get isEnabled =>
      _featureState?.type == FeatureValueType.BOOLEAN && _value == true;

  set featureState(FeatureState fs) {
    _featureState = fs;
    final oldValue = _value;
    _value = fs.value;
    if (oldValue != _value) {
      _listeners!.add(this);
    }
  }

  @override
  int? get version => _featureState?.version;

  @override
  bool get exists => _findIntercept(() => _value) != null;

  @override
  bool? get booleanValue => _findIntercept(
          () => _featureState?.type == FeatureValueType.BOOLEAN ? _value : null)
      as bool?;

  @override
  String? get stringValue =>
      _findIntercept(() => (_featureState?.type == FeatureValueType.STRING ||
              _featureState?.type == FeatureValueType.JSON)
          ? _value
          : null) as String?;

  @override
  num? get numberValue => _findIntercept(
          () => _featureState?.type == FeatureValueType.NUMBER ? _value : null)
      as num?;

  @override
  dynamic get jsonValue {
    String? body = _findIntercept(
        () => _featureState?.type == FeatureValueType.JSON ? _value : null);

    return body == null ? null : jsonDecode(body);
  }

  @override
  FeatureValueType? get type => _featureState!.type;

  @override
  FeatureStateHolder copy() {
    return _FeatureStateBaseHolder(null, featureValueInterceptors)
      ..featureState = _featureState!;
  }

  dynamic _findIntercept(Function determineDefault) {
    final locked = _featureState != null && true == _featureState!.l;

    final found = featureValueInterceptors
        .where((vi) => !locked || vi.allowLockOverride)
        .map((vi) {
      final vm = vi.interceptor(key);
      return vm.matched ? vm : null;
    }).where((vm) => vm != null);

    return found.isNotEmpty ? found.first : determineDefault();
  }

  void shutdown() {
    _listeners!.close();
  }
}

final _log = Logger('FeatureHub');

class ClientFeatureRepository {
  bool _hasReceivedInitialState = false;
  // indexed by key
  final Map<String?, _FeatureStateBaseHolder> _features = {};
  final _analyticsCollectors = PublishSubject<AnalyticsEvent>();
  Readyness _readynessState = Readyness.NotReady;
  final _readynessListeners =
      BehaviorSubject<Readyness>.seeded(Readyness.NotReady);
  final _newFeatureStateAvailableListeners =
      PublishSubject<ClientFeatureRepository>();
  bool _catchAndReleaseMode = false;
  // indexed by id (not key)
  final Map<String?, FeatureState> _catchReleaseStates = {};
  final List<_InterceptorHolder> _featureValueInterceptors = [];
  final ClientContext clientContext = ClientContext();

  Stream<Readyness> get readynessStream => _readynessListeners.stream;
  Stream<ClientFeatureRepository> get newFeatureStateAvailableStream =>
      _newFeatureStateAvailableListeners.stream;
  Stream<AnalyticsEvent> get analyticsEvent => _analyticsCollectors.stream;

  Iterable<String?> get availableFeatures => _features.keys;

  /// used by a provider of features to tell the repository about updates to those features.
  /// If you were storing features on your device you could use this to fill the repository before it was connected for example.
  void notify(SSEResultState? state, dynamic data) {
    _log.fine('Data is $state -> $data');
    if (state != null) {
      switch (state) {
        case SSEResultState.ack:
          break;
        case SSEResultState.bye:
          _readynessState = Readyness.NotReady;
          if (!_catchAndReleaseMode) {
            _broadcastReadynessState();
          }
          break;
        case SSEResultState.failure:
          _readynessState = Readyness.Failed;
          if (!_catchAndReleaseMode) {
            _broadcastReadynessState();
          }
          break;
        case SSEResultState.features:
          final features = (data is List<FeatureState>)
              ? data
              : FeatureState.listFromJson(data);
          if (_hasReceivedInitialState && _catchAndReleaseMode) {
            _catchUpdatedFeatures(features);
          } else {
            var _updated = false;
            features.forEach((f) => _updated = _featureUpdate(f) || _updated);
            if (!_hasReceivedInitialState) {
              _checkForInvalidFeatures();
              _hasReceivedInitialState = true;
            } else if (_updated) {
              _triggerNewStateAvailable();
            }
            _readynessState = Readyness.Ready;
            _broadcastReadynessState();
          }
          break;
        case SSEResultState.feature:
          final feature = FeatureState.fromJson(data);
          if (_catchAndReleaseMode) {
            _catchUpdatedFeatures([feature]);
          } else {
            if (_featureUpdate(feature)) {
              _triggerNewStateAvailable();
            }
          }
          break;
        case SSEResultState.deleteFeature:
          _deleteFeature(FeatureState.fromJson(data));
          break;
        case SSEResultState.config:
          throw UnimplementedError();
        case SSEResultState.error:
          throw UnimplementedError();
      }
    }
  }

  void _broadcastReadynessState() {
    _readynessListeners.add(_readynessState);
  }

  void _catchUpdatedFeatures(List<FeatureState> features) {
    var updatedValues = false;
    for (var f in features) {
      final fs = _catchReleaseStates[f.id];
      if (fs == null) {
        _catchReleaseStates[f.id] = f;
        updatedValues = true;
      } else {
        if (fs.version == null || f.version! > fs.version!) {
          _catchReleaseStates[f.id] = f;
          updatedValues = true;
        }
      }
    }

    if (updatedValues) {
      _triggerNewStateAvailable();
    }
  }

  void _checkForInvalidFeatures() {
    final missingKeys = _features.keys
        .where((k) => _features[k]!.key == null)
        .toList()
        .join(',');
    if (missingKeys.isNotEmpty) {
      _log.info('We have requests for keys that are missing: $missingKeys');
    }
  }

  void _triggerNewStateAvailable() {
    if (_hasReceivedInitialState) {
      if (!_catchAndReleaseMode || _catchReleaseStates.isNotEmpty) {
        _newFeatureStateAvailableListeners.add(this);
      }
    }
  }

  /// allows us to log an analytics event with this set of features
  void logAnalyticsEvent(String action, {Map<String, Object>? other}) {
    final featureStateAtCurrentTime =
        _features.values.where((f) => f.exists).map((f) => f.copy()).toList();

    _analyticsCollectors
        .add(AnalyticsEvent(action, featureStateAtCurrentTime, other));
  }

  /// returns [FeatureStateHolder] if feature key exists or [null] if the feature value is not set or does not exist
  FeatureStateHolder getFeatureState(String? key) {
    return _features.putIfAbsent(
        key, () => _FeatureStateBaseHolder(null, _featureValueInterceptors));
  }

  ///returns [FeatureStateHolder] if feature key exists or [null] if the feature value is not set or does not exist
  FeatureStateHolder feature(String? key) {
    return getFeatureState(key);
  }

  /// @param key The feature key
  /// @returns A boolean (flag) feature value or [null] if the feature does not exist.
  bool? getFlag(String key) {
    return feature(key).booleanValue;
  }

  /// @param key The feature key
  /// @returns The value of the number feature or [null]
  /// if the feature value not set or does not exist
  num? getNumber(String key) {
    return feature(key).numberValue;
  }

  /// @param key The feature key
  /// @returns The value of the string feature or [null]
  /// if the feature value not set or does not exist
  String? getString(String key) {
    return feature(key).stringValue;
  }

  /// @param key The feature key
  /// @returns The value of the json feature or [null]
  /// if the feature value not set or does not exist
  dynamic getJson(String key) {
    return feature(key).jsonValue;
  }

  bool isSet(String key) {
    return feature(key).isSet;
  }

  bool isEnabled(String key) {
    return feature(key).isEnabled;
  }

  /// @param key The feature key
  /// returns true if the feature key exists, otherwise false
  bool exists(String key) {
    return feature(key).exists;
  }

  bool get catchAndReleaseMode => _catchAndReleaseMode;
  set catchAndReleaseMode(bool val) {
    if (_catchAndReleaseMode && !val) {
      release(disableCatchAndRelease: true);
    } else {
      _catchAndReleaseMode = val;
    }
  }

  Readyness get readyness => _readynessState;

  Future<void> release({bool disableCatchAndRelease = false}) async {
    while (_catchReleaseStates.isNotEmpty) {
      final states = <FeatureState>[..._catchReleaseStates.values];
      _catchReleaseStates.clear();
      states.forEach((f) => _featureUpdate(f));
    }

    if (disableCatchAndRelease == true) {
      _catchAndReleaseMode = false;
    }
  }

  bool _featureUpdate(FeatureState feature) {
    var holder = _features[feature.key];

    if (holder == null || holder.key == null) {
      holder = _FeatureStateBaseHolder(holder, _featureValueInterceptors);
    } else {
      if (holder.version != null) {
        if (holder.version! > feature.version! ||
            (holder.version == feature.version &&
                holder.value == feature.value)) {
          return false;
        }
      }
    }

    holder.featureState = feature;
    _features[feature.key] = holder;

    return true;
  }

  /// register an interceptor, indicating whether it is allowed to override
  /// the locking coming from the server
  void registerFeatureValueInterceptor(
      bool allowLockOverride, FeatureValueInterceptor fvi) {
    _featureValueInterceptors.add(_InterceptorHolder(allowLockOverride, fvi));
  }

  void _deleteFeature(FeatureState feature) {
    _features.remove(feature.key);
  }

  /// call this to clear the repository if you are swapping environments
  void shutdownFeatures() {
    _features.values.forEach((f) => f.shutdown());
    _features.clear();
  }

  /// after this method is called, the repository is not usable, create a new one.
  void shutdown() {
    _readynessListeners.close();
    _newFeatureStateAvailableListeners.close();
    _analyticsCollectors.close();
    shutdownFeatures();
  }
}
