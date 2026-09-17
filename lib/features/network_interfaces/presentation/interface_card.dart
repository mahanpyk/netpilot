import 'package:flutter/material.dart';

import '../../../core/models/network_interface_info.dart';

class InterfaceCard extends StatelessWidget {
  const InterfaceCard({super.key, required this.info});

  final NetworkInterfaceInfo info;

  IconData get _icon => switch (info.kind) {
        NetworkInterfaceKind.wifi => Icons.wifi,
        NetworkInterfaceKind.ethernet => Icons.settings_ethernet,
        NetworkInterfaceKind.other => Icons.device_hub,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_icon, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    info.name.isEmpty ? info.interfaceName : info.name,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                if (info.isDefaultRoute)
                  Chip(
                    label: const Text('Default'),
                    visualDensity: VisualDensity.compact,
                    backgroundColor:
                        theme.colorScheme.primaryContainer.withValues(alpha: 0.7),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            _kv('Interface', info.interfaceName),
            _kv(
              'IPv4',
              info.ipv4Addresses.isEmpty
                  ? '—'
                  : info.ipv4Addresses.join(', '),
            ),
            _kv('Gateway', info.gateway ?? '—'),
            _kv(
              'DNS',
              info.dnsServers.isEmpty ? '—' : info.dnsServers.join(', '),
            ),
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(k, style: const TextStyle(fontWeight: FontWeight.w500)),
          ),
          Expanded(child: Text(v)),
        ],
      ),
    );
  }
}
