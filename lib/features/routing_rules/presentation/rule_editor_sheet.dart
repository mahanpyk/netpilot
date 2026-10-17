import 'package:flutter/material.dart';

import '../../../core/models/network_interface_info.dart';
import '../../../core/models/routing_rule.dart';
import '../../../core/utils/destination_parser.dart';
import '../domain/netpilot_controller.dart';

class RuleEditorSheet extends StatefulWidget {
  const RuleEditorSheet({super.key, required this.controller, this.existing});

  final NetPilotController controller;
  final RoutingRule? existing;

  @override
  State<RuleEditorSheet> createState() => _RuleEditorSheetState();
}

class _RuleEditorSheetState extends State<RuleEditorSheet> {
  late final TextEditingController _destination;
  late final TextEditingController _label;
  late final TextEditingController _hostIpv4;
  bool _manageHostname = false;
  String? _interfaceId;
  String? _error;
  List<String> _previewIps = [];
  bool _resolving = false;
  bool _saving = false;
  bool _scanningDependencies = false;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _destination = TextEditingController(text: existing?.rawDestination ?? '');
    _label = TextEditingController(text: existing?.label ?? '');
    _hostIpv4 = TextEditingController(text: existing?.hostIpv4 ?? '');
    _manageHostname =
        widget.controller.supportsHostMappings &&
        (existing == null || existing.hostIpv4 != null);
    _interfaceId =
        existing?.interfaceId ??
        widget.controller.activeInterfaces
            .where((i) => i.kind == NetworkInterfaceKind.ethernet)
            .map((i) => i.nativeId)
            .cast<String?>()
            .firstWhere((_) => true, orElse: () => null) ??
        widget.controller.activeInterfaces
            .map((i) => i.nativeId)
            .cast<String?>()
            .firstWhere((_) => true, orElse: () => null);
    _previewIps = existing?.resolvedIps ?? [];
  }

  @override
  void dispose() {
    _destination.dispose();
    _label.dispose();
    _hostIpv4.dispose();
    super.dispose();
  }

  Future<void> _preview() async {
    setState(() {
      _error = null;
      _resolving = true;
    });
    try {
      final parsed = widget.controller.previewDestination(_destination.text);
      final isHostname =
          (parsed.kind == DestinationKind.hostname ||
              parsed.kind == DestinationKind.url) &&
          !const DestinationParser().isIpv4(parsed.normalized);
      if (isHostname && _manageHostname && _hostIpv4.text.trim().isNotEmpty) {
        final ip = _hostIpv4.text.trim();
        if (!const DestinationParser().isIpv4(ip)) {
          throw DestinationParseException('Enter a valid LAN IPv4 address.');
        }
        setState(() => _previewIps = [ip]);
        return;
      }
      if (parsed.kind == DestinationKind.hostname ||
          parsed.kind == DestinationKind.url) {
        final ips = await widget.controller.resolvePreview(
          parsed.normalized,
          interfaceId: _interfaceId,
        );
        if (!mounted) return;
        setState(() => _previewIps = ips);
        if (ips.isEmpty) {
          setState(() => _error = 'No A records for ${parsed.normalized}');
        }
      } else if (parsed.kind == DestinationKind.ipv4) {
        setState(() => _previewIps = [parsed.normalized]);
      } else {
        setState(() => _previewIps = [parsed.normalized]);
      }
    } on DestinationParseException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _previewIps = [];
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  Future<void> _save() async {
    if (_interfaceId == null) {
      setState(() => _error = 'Select a LAN interface');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final parsed = widget.controller.previewDestination(_destination.text);
      final isHostname =
          (parsed.kind == DestinationKind.hostname ||
              parsed.kind == DestinationKind.url) &&
          !const DestinationParser().isIpv4(parsed.normalized);
      if (parsed.kind == DestinationKind.url) {
        setState(() => _scanningDependencies = true);
      }
      await widget.controller.upsertRule(
        id: widget.existing?.id,
        rawDestination: _destination.text,
        interfaceId: _interfaceId!,
        label: _label.text.trim().isEmpty ? null : _label.text.trim(),
        enabled: widget.existing?.enabled ?? true,
        hostIpv4: isHostname && _manageHostname ? _hostIpv4.text : null,
        manageHostname: isHostname && _manageHostname,
      );
      if (mounted) Navigator.of(context).pop();
    } on DestinationParseException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _scanningDependencies = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ifaces = widget.controller.activeInterfaces;
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    var isHostname = false;
    try {
      final parsed = widget.controller.previewDestination(_destination.text);
      isHostname =
          (parsed.kind == DestinationKind.hostname ||
              parsed.kind == DestinationKind.url) &&
          !const DestinationParser().isIpv4(parsed.normalized);
    } on DestinationParseException {
      // Show the DNS controls once a valid hostname has been entered.
    }
    return SingleChildScrollView(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 8, 20, 20 + bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.existing == null
                  ? 'Add routing rule'
                  : 'Edit routing rule',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _destination,
              enabled: !_saving,
              decoration: const InputDecoration(
                labelText: 'Destination',
                hintText: 'intranet.company.local or 10.0.0.0/8 or https://…',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _label,
              enabled: !_saving,
              decoration: const InputDecoration(labelText: 'Label (optional)'),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _interfaceId,
              decoration: const InputDecoration(
                labelText: 'Send via interface',
              ),
              items: ifaces
                  .map(
                    (i) => DropdownMenuItem(
                      value: i.nativeId,
                      child: Text(
                        '${i.name.isEmpty ? i.interfaceName : i.name} (${i.interfaceName})'
                        '${i.isDefaultRoute ? ' · default' : ''}',
                      ),
                    ),
                  )
                  .toList(),
              onChanged: _saving
                  ? null
                  : (v) => setState(() => _interfaceId = v),
            ),
            const SizedBox(height: 12),
            if (widget.controller.supportsHostMappings && isHostname) ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Make this LAN hostname available to other apps',
                ),
                subtitle: const Text(
                  'NetPilot saves a private LAN DNS address in hosts while this rule is enabled. Existing manual entries are preserved.',
                ),
                value: _manageHostname,
                onChanged: _saving || _resolving
                    ? null
                    : (value) => setState(() => _manageHostname = value),
              ),
              if (_manageHostname)
                TextField(
                  controller: _hostIpv4,
                  enabled: !_saving && !_resolving,
                  decoration: const InputDecoration(
                    labelText: 'LAN IPv4 (optional override)',
                    hintText: '192.168.1.20',
                    helperText: 'Leave blank to use LAN DNS. Enter the IP if DNS is missing or incorrect. Saved mappings stay fixed until edited.',
                    helperMaxLines: 3,
                  ),
                ),
              const SizedBox(height: 12),
            ],
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _resolving || _saving ? null : _preview,
                  icon: _resolving
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.travel_explore),
                  label: const Text('Resolve preview'),
                ),
                const SizedBox(width: 12),
                if (_previewIps.isNotEmpty)
                  Expanded(
                    child: Text(
                      '→ ${_previewIps.join(', ')}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _saving || _resolving ? null : _save,
              child: Text(
                _scanningDependencies
                    ? 'Saving & scanning dependencies…'
                    : (_saving ? 'Saving…' : 'Save & apply'),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
