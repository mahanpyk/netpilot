import '../models/routing_rule.dart';

class RouteDiff {
  const RouteDiff({
    required this.toAdd,
    required this.toRemove,
    required this.unchanged,
  });

  final List<DesiredRoute> toAdd;
  final List<DesiredRoute> toRemove;
  final List<DesiredRoute> unchanged;

  bool get isEmpty => toAdd.isEmpty && toRemove.isEmpty;
}

class RoutePlan {
  const RoutePlan({
    required this.routes,
    required this.conflictsByRuleId,
    required this.conflictsBySubRuleKey,
  });

  final List<DesiredRoute> routes;
  final Map<String, List<String>> conflictsByRuleId;
  final Map<String, List<String>> conflictsBySubRuleKey;

  bool get hasConflicts => conflictsByRuleId.isNotEmpty;
}

/// Computes add/remove sets between desired and currently managed routes.
class RouteReconciler {
  const RouteReconciler();

  RouteDiff diff({
    required Iterable<DesiredRoute> desired,
    required Iterable<DesiredRoute> current,
  }) {
    final desiredSet = desired.toSet();
    final currentSet = current.toSet();

    final toAdd = desiredSet.difference(currentSet).toList();
    final toRemove = currentSet.difference(desiredSet).toList();
    final unchanged = desiredSet.intersection(currentSet).toList();

    return RouteDiff(toAdd: toAdd, toRemove: toRemove, unchanged: unchanged);
  }

  /// Expand enabled rules into desired /32 or CIDR routes.
  List<DesiredRoute> desiredFromRules(
    Iterable<RoutingRule> rules, {
    required String Function(RoutingRule rule) gatewayFor,
  }) {
    return planFromRules(rules, gatewayFor: gatewayFor).routes;
  }

  /// Expands parent and sub-rules, de-duplicates equivalent destinations, and
  /// excludes exact destination conflicts that target different interfaces.
  RoutePlan planFromRules(
    Iterable<RoutingRule> rules, {
    required String Function(RoutingRule rule) gatewayFor,
  }) {
    final candidates = <_RouteCandidate>[];
    for (final rule in rules) {
      if (!rule.enabled) continue;
      final gateway = gatewayFor(rule).trim();
      candidates.addAll(
        _expandDestination(
          parentRuleId: rule.id,
          routeRuleId: rule.id,
          kind: rule.kind,
          destination: rule.normalizedDestination,
          resolvedIps: rule.resolvedIps,
          interfaceName: rule.interfaceId,
          gateway: gateway.isEmpty ? null : gateway,
        ),
      );
      for (final subRule in rule.subRules) {
        if (!subRule.enabled) continue;
        candidates.addAll(
          _expandDestination(
            parentRuleId: rule.id,
            subRuleId: subRule.id,
            routeRuleId: '${rule.id}:sub:${subRule.id}',
            kind: subRule.kind,
            destination: subRule.destination,
            resolvedIps: subRule.resolvedIps,
            interfaceName: rule.interfaceId,
            gateway: gateway.isEmpty ? null : gateway,
          ),
        );
      }
    }

    final byDestination = <String, List<_RouteCandidate>>{};
    for (final candidate in candidates) {
      byDestination
          .putIfAbsent(candidate.route.destinationCidr, () => [])
          .add(candidate);
    }

    final routes = <DesiredRoute>[];
    final conflictsByRuleId = <String, List<String>>{};
    final conflictsBySubRuleKey = <String, List<String>>{};
    for (final entry in byDestination.entries) {
      final signatures = entry.value
          .map(
            (candidate) =>
                (candidate.route.interfaceName, candidate.route.gateway),
          )
          .toSet();
      if (signatures.length > 1) {
        final interfaces =
            entry.value
                .map((candidate) => candidate.route.interfaceName)
                .toSet()
                .toList()
              ..sort();
        final message =
            'Route conflict for ${entry.key}: requested via ${interfaces.join(' and ')}; destination was not applied.';
        for (final candidate in entry.value) {
          conflictsByRuleId
              .putIfAbsent(candidate.parentRuleId, () => [])
              .add(message);
          final subRuleId = candidate.subRuleId;
          if (subRuleId != null) {
            conflictsBySubRuleKey
                .putIfAbsent('${candidate.parentRuleId}:$subRuleId', () => [])
                .add(message);
          }
        }
        continue;
      }

      final equivalent = entry.value.toList()
        ..sort((a, b) => a.route.ruleId.compareTo(b.route.ruleId));
      routes.add(equivalent.first.route);
    }

    routes.sort((a, b) {
      final destination = a.destinationCidr.compareTo(b.destinationCidr);
      return destination != 0 ? destination : a.ruleId.compareTo(b.ruleId);
    });
    return RoutePlan(
      routes: routes,
      conflictsByRuleId: conflictsByRuleId,
      conflictsBySubRuleKey: conflictsBySubRuleKey,
    );
  }

  List<_RouteCandidate> _expandDestination({
    required String parentRuleId,
    required String routeRuleId,
    required DestinationKind kind,
    required String destination,
    required List<String> resolvedIps,
    required String interfaceName,
    required String? gateway,
    String? subRuleId,
  }) {
    final cidrs = switch (kind) {
      DestinationKind.cidr => [destination],
      DestinationKind.ipv4 => ['$destination/32'],
      DestinationKind.hostname ||
      DestinationKind.url => [for (final ip in resolvedIps) '$ip/32'],
    };
    return [
      for (final cidr in cidrs)
        _RouteCandidate(
          parentRuleId: parentRuleId,
          subRuleId: subRuleId,
          route: DesiredRoute(
            destinationCidr: cidr,
            gateway: gateway,
            interfaceName: interfaceName,
            ruleId: routeRuleId,
          ),
        ),
    ];
  }
}

class _RouteCandidate {
  const _RouteCandidate({
    required this.parentRuleId,
    required this.route,
    this.subRuleId,
  });

  final String parentRuleId;
  final String? subRuleId;
  final DesiredRoute route;
}
