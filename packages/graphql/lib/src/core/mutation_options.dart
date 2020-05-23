import 'package:graphql/src/cache/cache.dart';
import 'package:graphql/src/core/_base_options.dart';
import 'package:graphql/src/core/observable_query.dart';
import 'package:meta/meta.dart';

import 'package:gql/ast.dart';
import 'package:gql_exec/gql_exec.dart';

import 'package:graphql/src/exceptions.dart';
import 'package:graphql/src/core/query_result.dart';
import 'package:graphql/src/utilities/helpers.dart';
import 'package:graphql/src/core/policies.dart';

typedef OnMutationCompleted = void Function(dynamic data);
typedef OnMutationUpdate = void Function(
  GraphQLDataProxy cache,
  QueryResult result,
);
typedef OnError = void Function(OperationException error);

class MutationOptions extends BaseOptions {
  MutationOptions({
    @required DocumentNode document,
    String operationName,
    Map<String, dynamic> variables,
    FetchPolicy fetchPolicy,
    ErrorPolicy errorPolicy,
    Context context,
    Object optimisticResult,
    this.onCompleted,
    this.update,
    this.onError,
  }) : super(
          fetchPolicy: fetchPolicy,
          errorPolicy: errorPolicy,
          document: document,
          operationName: operationName,
          variables: variables,
          context: context,
          optimisticResult: optimisticResult,
        );

  final OnMutationCompleted onCompleted;
  final OnMutationUpdate update;
  final OnError onError;

  @override
  List<Object> get properties =>
      [...super.properties, onCompleted, update, onError];

  MutationOptions copyWith({
    DocumentNode document,
    String operationName,
    Map<String, dynamic> variables,
    Context context,
    FetchPolicy fetchPolicy,
    ErrorPolicy errorPolicy,
    Object optimisticResult,
    OnMutationCompleted onCompleted,
    OnMutationUpdate update,
    OnError onError,
  }) =>
      MutationOptions(
        document: document ?? this.document,
        operationName: operationName ?? this.operationName,
        variables: variables ?? this.variables,
        context: context ?? this.context,
        fetchPolicy: fetchPolicy ?? this.fetchPolicy,
        errorPolicy: errorPolicy ?? this.errorPolicy,
        optimisticResult: optimisticResult ?? this.optimisticResult,
        onCompleted: onCompleted ?? this.onCompleted,
        update: update ?? this.update,
        onError: onError ?? this.onError,
      );
}

/// Handles execution of mutation `update`, `onCompleted`, and `onError` callbacks
class MutationCallbackHandler {
  final MutationOptions options;
  final GraphQLCache cache;
  final String queryId;

  MutationCallbackHandler({
    this.options,
    this.cache,
    this.queryId,
  })  : assert(cache != null),
        assert(options != null),
        assert(queryId != null);

  // callbacks will be called against each result in the stream,
  // which should then rebroadcast queries with the appropriate optimism
  Iterable<OnData> get callbacks =>
      <OnData>[onCompleted, update, onError].where(notNull);

  // Todo: probably move this to its own class
  OnData get onCompleted {
    if (options.onCompleted != null) {
      return (QueryResult result) {
        if (!result.isLoading && !result.isOptimistic) {
          return options.onCompleted(result.data);
        }
      };
    }
    return null;
  }

  OnData get onError {
    if (options.onError != null) {
      return (QueryResult result) {
        if (!result.isLoading &&
            result.hasException &&
            options.errorPolicy != ErrorPolicy.ignore) {
          return options.onError(result.exception);
        }
      };
    }

    return null;
  }

  /// The optimistic cache layer id `update` will write to
  /// is a "child patch" of the default optimistic patch
  /// created by the query manager
  String get _patchId => '${queryId}.update';

  /// apply the user's patch
  void _optimisticUpdate(QueryResult result) {
    final String patchId = _patchId;
    // this is also done in query_manager, but better safe than sorry
    cache.recordOptimisticTransaction(
      (GraphQLDataProxy cache) {
        options.update(cache, result);
        return cache;
      },
      patchId,
    );
  }

  // optimistic patches will be cleaned up by the query_manager
  // cleanup is handled by heirarchical optimism -
  // as in, because our patch id is prefixed with '${observableQuery.queryId}.',
  // it will be discarded along with the observableQuery.queryId patch
  // TODO this results in an implicit coupling with the patch id system
  OnData get update {
    if (options.update != null) {
      // dereference all variables that might be needed if the widget is disposed
      final OnMutationUpdate widgetUpdate = options.update;
      final OnData optimisticUpdate = _optimisticUpdate;

      // wrap update logic to handle optimism
      void updateOnData(QueryResult result) {
        if (result.isOptimistic) {
          return optimisticUpdate(result);
        } else {
          return widgetUpdate(cache, result);
        }
      }

      return updateOnData;
    }
    return null;
  }
}