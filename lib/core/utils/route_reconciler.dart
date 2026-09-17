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
    final out = <DesiredRoute>[];
    for (final rule in rules) {
      if (!rule.enabled) continue;
      if (rule.kind == DestinationKind.cidr) {
        out.add(
          DesiredRoute(
            destinationCidr: rule.normalizedDestination,
            gateway: gatewayFor(rule),
            interfaceName: rule.interfaceId,
            ruleId: rule.id,
          ),
        );
        continue;
      }
      if (rule.kind == DestinationKind.ipv4) {
        out.add(
          DesiredRoute(
            destinationCidr: '${rule.normalizedDestination}/32',
            gateway: gatewayFor(rule),
            interfaceName: rule.interfaceId,
            ruleId: rule.id,
          ),
        );
        continue;
      }
      for (final ip in rule.resolvedIps) {
        out.add(
          DesiredRoute(
            destinationCidr: '$ip/32',
            gateway: gatewayFor(rule),
            interfaceName: rule.interfaceId,
            ruleId: rule.id,
          ),
        );
      }
    }
    return out;
  }
}
