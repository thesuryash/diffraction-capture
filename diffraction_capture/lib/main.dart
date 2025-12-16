import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  runApp(const DiffractionApp());
}

class DiffractionApp extends StatelessWidget {
  const DiffractionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return RoiProvider(
      notifier: RoiState(),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Diffraction Capture',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF2563EB),
            surface: Colors.white,
          ),
          scaffoldBackgroundColor: const Color(0xFFF4F5F7),
          textTheme: ThemeData.light().textTheme.apply(
            bodyColor: const Color(0xFF0F172A),
            displayColor: const Color(0xFF0F172A),
          ),
          useMaterial3: true,
        ),
        home: const ResponsiveRoot(),
      ),
    );
  }
}

class RoiState extends ChangeNotifier {
  static final Rect defaultNormalizedRect = Rect.fromLTWH(0.2, 0.2, 0.6, 0.6);

  Rect _normalizedRect = defaultNormalizedRect;
  Size? _previewSize;

  Rect get normalizedRect => _normalizedRect;
  Size? get previewSize => _previewSize;

  void reset() {
    _normalizedRect = defaultNormalizedRect;
    notifyListeners();
  }

  void updateRect(Rect rect) {
    _normalizedRect = _clampRect(rect);
    notifyListeners();
  }

  void updatePreviewSize(Size size) {
    if (_previewSize == size) return;
    _previewSize = size;
    notifyListeners();
  }

  Rect pixelRectFor(Size size) {
    final rect = _normalizedRect;
    return Rect.fromLTWH(
      rect.left * size.width,
      rect.top * size.height,
      rect.width * size.width,
      rect.height * size.height,
    );
  }

  Rect _clampRect(Rect rect) {
    const double minSize = 0.08;
    double left = rect.left.clamp(0.0, 1.0);
    double top = rect.top.clamp(0.0, 1.0);
    double right = rect.right.clamp(0.0, 1.0);
    double bottom = rect.bottom.clamp(0.0, 1.0);

    if (right - left < minSize) {
      right = min(1.0, left + minSize);
    }
    if (bottom - top < minSize) {
      bottom = min(1.0, top + minSize);
    }

    return Rect.fromLTRB(left, top, right, bottom);
  }
}

class RoiProvider extends InheritedNotifier<RoiState> {
  const RoiProvider({
    super.key,
    required RoiState notifier,
    required Widget child,
  }) : super(notifier: notifier, child: child);

  static RoiState of(BuildContext context) {
    final provider = context.dependOnInheritedWidgetOfExactType<RoiProvider>();
    assert(provider != null, 'RoiProvider is missing from the widget tree');
    return provider!.notifier!;
  }
}

class ResponsiveRoot extends StatelessWidget {
  const ResponsiveRoot({super.key});

  bool _isDesktopLayout(BoxConstraints constraints) {
    if (!kIsWeb &&
        (Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
      return true;
    }
    return constraints.maxWidth > 900 || kIsWeb;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ReferenceData>(
      future: ReferenceDataLoader.load(),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final data = snapshot.data ?? ReferenceData.empty();
        return LayoutBuilder(
          builder: (context, constraints) {
            if (_isDesktopLayout(constraints)) {
              return DesktopDashboard(data: data);
            }
            return MobileHomeShell(data: data);
          },
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Desktop Experience (desktop/tablet)
// ---------------------------------------------------------------------------

class DesktopDashboard extends StatefulWidget {
  final ReferenceData data;

  const DesktopDashboard({super.key, required this.data});

  @override
  State<DesktopDashboard> createState() => _DesktopDashboardState();
}

class _DesktopDashboardState extends State<DesktopDashboard> {
  late List<ProjectData> _projects;
  late List<SessionData> _sessions;
  Stats? _stats;
  ProjectData? _activeProject;
  final ScrollController _mainScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _projects = widget.data.projects;
    _sessions = widget.data.sessions;
    _stats = widget.data.stats;
    _activeProject = _projects.isEmpty
        ? null
        : _projects.firstWhere(
            (p) => p.isActive,
            orElse: () => _projects.first,
          );
    if (!kIsWeb &&
        (Platform.isMacOS || Platform.isWindows || Platform.isLinux) &&
        _activeProject != null) {
      PairingHost.instance.startForProject(_activeProject!.name);
    }
  }

  @override
  void dispose() {
    PairingHost.instance.stop();
    _mainScroll.dispose();
    super.dispose();
  }

  void _setActiveProject(ProjectData? project) {
    setState(() {
      _activeProject = project;
      _projects = _projects
          .map(
            (p) =>
                p.copyWith(isActive: project != null && p.name == project.name),
          )
          .toList();
    });
    if (!kIsWeb &&
        (Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
      if (project != null) {
        PairingHost.instance.startForProject(project.name);
      } else {
        PairingHost.instance.stop();
      }
    }
  }

  void _showSnack(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _createProject(BuildContext context) async {
    final controller = TextEditingController();
    final created = await showDialog<ProjectData>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('New Project'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(labelText: 'Project name'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                if (controller.text.trim().isEmpty) return;
                Navigator.pop(
                  ctx,
                  ProjectData(
                    name: controller.text.trim(),
                    sessions: 0,
                    isActive: true,
                  ),
                );
              },
              child: const Text('Create'),
            ),
          ],
        );
      },
    );

    if (!mounted) return;

    if (created != null) {
      setState(() {
        _projects = [
          created,
          ..._projects.map((p) => p.copyWith(isActive: false)),
        ];
        _activeProject = created;
      });
      _showSnack(context, 'Project "${created.name}" created');
    }
  }

  void _openSettings(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Settings'),
        content: const Text(
          'Settings panel coming soon. Pairing and projects are active.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _importData(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import Data'),
        content: const Text(
          'Drag a session archive into this window to import. For now this will simulate a successful import.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() {
                final extra = SessionData(
                  title: 'Imported Session ${_sessions.length + 1}',
                  date: DateTime.now().toIso8601String().split('T').first,
                  images: 3,
                  temps: 1,
                  status: 'Imported',
                  statusColor: const Color(0xFF22C55E),
                  icon: Icons.file_upload_outlined,
                  iconColor: const Color(0xFF8B5CF6),
                );
                _sessions = [extra, ..._sessions];
                _stats = _stats?.copyWith(
                  sessions: (_stats?.sessions ?? 0) + 1,
                  images: (_stats?.images ?? 0) + extra.images,
                );
              });
              _showSnack(
                context,
                'Import completed and added to recent sessions',
              );
            },
            child: const Text('Simulate Import'),
          ),
        ],
      ),
    );
  }

  void _connectPhone(BuildContext context) {
    if (_activeProject == null) {
      _showSnack(context, 'Select or create a project before pairing.');
      return;
    }
    PairingHost.instance.startForProject(_activeProject!.name);
    _showSnack(context, 'Pairing service ready for ${_activeProject!.name}.');
  }

  void _openSession(SessionData session) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(session.title),
        content: Text(
          'Captured on ${session.date}\n${session.images} images • ${session.temps} temps',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _viewAllSessions() {
    _mainScroll.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1400),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 280,
                  child: _Sidebar(
                    projects: _projects,
                    activeProject: _activeProject,
                    onProjectSelected: _setActiveProject,
                    pairingCard: PairingCard(activeProject: _activeProject),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Header(
                        onNewProject: () => _createProject(context),
                        onOpenSettings: () => _openSettings(context),
                      ),
                      const SizedBox(height: 16),
                      Expanded(
                        child: _MainContent(
                          sessions: _sessions,
                          stats: _stats ?? widget.data.stats,
                          onNewProject: () => _createProject(context),
                          onImport: () => _importData(context),
                          onConnectPhone: () => _connectPhone(context),
                          onOpenSession: _openSession,
                          onViewAll: _viewAllSessions,
                          scrollController: _mainScroll,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class Header extends StatelessWidget {
  final VoidCallback onNewProject;
  final VoidCallback onOpenSettings;

  const Header({
    super.key,
    required this.onNewProject,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE5E7EB)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF2563EB),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.compass_calibration_rounded,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Text(
                'Diffraction Capture',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              SizedBox(height: 2),
              Text(
                'Desktop Analysis Suite',
                style: TextStyle(
                  color: Color(0xFF6B7280),
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const Spacer(),
          ElevatedButton.icon(
            onPressed: onNewProject,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2563EB),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            icon: const Icon(Icons.add),
            label: const Text('New Project'),
          ),
          const SizedBox(width: 10),
          IconButton(
            onPressed: onOpenSettings,
            icon: const Icon(Icons.settings_outlined),
            color: const Color(0xFF4B5563),
          ),
        ],
      ),
    );
  }
}

class _MainContent extends StatelessWidget {
  final List<SessionData> sessions;
  final Stats stats;
  final VoidCallback onNewProject;
  final VoidCallback onImport;
  final VoidCallback onConnectPhone;
  final VoidCallback onViewAll;
  final ValueChanged<SessionData> onOpenSession;
  final ScrollController scrollController;

  const _MainContent({
    required this.sessions,
    required this.stats,
    required this.onNewProject,
    required this.onImport,
    required this.onConnectPhone,
    required this.onViewAll,
    required this.onOpenSession,
    required this.scrollController,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: scrollController,
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Text(
            'Welcome back',
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          const Text(
            'Manage your diffraction analysis projects and sessions',
            style: TextStyle(
              color: Color(0xFF6B7280),
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _ActionCard(
                icon: Icons.add_box_outlined,
                title: 'New Project',
                subtitle: 'Start a new analysis project',
                color: const Color(0xFF2563EB),
                onTap: onNewProject,
              ),
              _ActionCard(
                icon: Icons.smartphone_outlined,
                title: 'Connect Phone',
                subtitle: 'Receive live capture data',
                color: const Color(0xFF22C55E),
                onTap: onConnectPhone,
              ),
              _ActionCard(
                icon: Icons.file_upload_outlined,
                title: 'Import Data',
                subtitle: 'Load existing session files',
                color: const Color(0xFF8B5CF6),
                onTap: onImport,
              ),
            ],
          ),
          const SizedBox(height: 24),
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      'Recent Sessions',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: onViewAll,
                      child: const Text('View All'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Column(
                  children: [
                    for (int i = 0; i < sessions.length; i++) ...[
                      SessionRow(
                        icon: sessions[i].icon,
                        iconColor: sessions[i].iconColor,
                        title: sessions[i].title,
                        meta:
                            '${sessions[i].date} • ${sessions[i].images} images • ${sessions[i].temps} temp records',
                        statusLabel: sessions[i].status,
                        statusColor: sessions[i].statusColor,
                        onOpen: () => onOpenSession(sessions[i]),
                      ),
                      if (i != sessions.length - 1) const Divider(height: 24),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _StatsRow(stats: stats),
        ],
      ),
    );
  }
}

class _Sidebar extends StatefulWidget {
  final List<ProjectData> projects;
  final ProjectData? activeProject;
  final ValueChanged<ProjectData?> onProjectSelected;
  final Widget pairingCard;

  const _Sidebar({
    super.key,
    required this.projects,
    required this.activeProject,
    required this.onProjectSelected,
    required this.pairingCard,
  });

  @override
  State<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<_Sidebar> {
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Scrollbar(
          controller: _scrollController,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _scrollController,
            padding: EdgeInsets.zero,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Card(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(bottom: 8.0),
                          child: Text(
                            'Projects',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                        ),
                        ...widget.projects.map((project) {
                          final isActive = project.isActive;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(12),
                              onTap: () => widget.onProjectSelected(project),
                              child: _SelectableTile(
                                title: project.name,
                                subtitle: '${project.sessions} sessions',
                                icon: isActive
                                    ? Icons.folder_special
                                    : Icons.folder_outlined,
                                isSelected: isActive,
                              ),
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  widget.pairingCard,
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE5E7EB)),
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F111827),
            blurRadius: 18,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _SelectableTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final bool isSelected;

  const _SelectableTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.isSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: isSelected ? const Color(0xFFEFF6FF) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isSelected ? const Color(0xFFBFDBFE) : const Color(0xFFE5E7EB),
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      child: Row(
        children: [
          Icon(
            icon,
            color: isSelected
                ? const Color(0xFF2563EB)
                : const Color(0xFF9CA3AF),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: Color(0xFF6B7280),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          const Icon(Icons.folder_zip_outlined, color: Color(0xFF9CA3AF)),
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  final Color color;
  const _StatusDot({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _ActionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback? onTap;

  const _ActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 310,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: _Card(
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withAlpha((0.12 * 255).round()),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF6B7280),
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Color(0xFF9CA3AF)),
            ],
          ),
        ),
      ),
    );
  }
}

class SessionRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String meta;
  final String statusLabel;
  final Color statusColor;
  final VoidCallback? onOpen;

  const SessionRow({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.meta,
    required this.statusLabel,
    required this.statusColor,
    this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
            color: iconColor.withAlpha((0.12 * 255).round()),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: iconColor),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                meta,
                style: const TextStyle(
                  color: Color(0xFF6B7280),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        StatusChip(label: statusLabel, color: statusColor),
        const SizedBox(width: 8),
        IconButton(
          onPressed: onOpen,
          icon: const Icon(Icons.chevron_right),
          color: const Color(0xFF9CA3AF),
        ),
      ],
    );
  }
}

class StatusChip extends StatelessWidget {
  final String label;
  final Color color;

  const StatusChip({super.key, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withAlpha((0.12 * 255).round()),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
    );
  }
}

class StatCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;

  const StatCard({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 250,
      child: _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: iconColor.withAlpha((0.12 * 255).round()),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: iconColor),
            ),
            const SizedBox(height: 12),
            Text(
              label,
              style: const TextStyle(
                color: Color(0xFF6B7280),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 26),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatsRow extends StatelessWidget {
  final Stats stats;

  const _StatsRow({required this.stats});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        StatCard(
          icon: Icons.folder,
          iconColor: const Color(0xFF2563EB),
          label: 'Total Projects',
          value: stats.projects.toString(),
        ),
        StatCard(
          icon: Icons.calendar_today_outlined,
          iconColor: const Color(0xFF22C55E),
          label: 'Total Sessions',
          value: stats.sessions.toString(),
        ),
        StatCard(
          icon: Icons.image_outlined,
          iconColor: const Color(0xFF8B5CF6),
          label: 'Images Processed',
          value: stats.images.toString(),
        ),
        StatCard(
          icon: Icons.thermostat,
          iconColor: const Color(0xFFF59E0B),
          label: 'Temp Records',
          value: stats.temps.toString(),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Mobile Experience
// ---------------------------------------------------------------------------

class MobileHomeShell extends StatelessWidget {
  final ReferenceData data;
  const MobileHomeShell({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Navigator(
        onGenerateRoute: (settings) {
          return MaterialPageRoute(builder: (_) => MobileHomePage(data: data));
        },
      ),
    );
  }
}

class MobileHomePage extends StatelessWidget {
  final ReferenceData data;

  const MobileHomePage({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final lastSession = data.lastSession;
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF2563EB), Color(0xFF1D4ED8)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Icon(Icons.auto_awesome, color: Colors.white, size: 56),
                const SizedBox(height: 16),
                const Text(
                  'Diffraction Capture',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Precision Material Analysis',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 48),
                _PrimaryButton(
                  label: 'New Session',
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => NewSessionFlow(data: data),
                      ),
                    );
                  },
                ),
                if (lastSession != null && lastSession.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _SecondaryButton(
                    label: 'Continue Last Session',
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ActiveCaptureScreen(
                            sessionName: lastSession,
                            status: CaptureStatus.zero(),
                          ),
                        ),
                      );
                    },
                  ),
                ],
                const SizedBox(height: 12),
                _SecondaryButton(
                  label: 'Session History',
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => SessionHistoryScreen(data: data),
                      ),
                    );
                  },
                ),
                const Spacer(),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      'PC Connection:',
                      style: TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      data.pcConnected ? Icons.check_circle : Icons.cancel,
                      color: data.pcConnected
                          ? Colors.lightGreenAccent
                          : Colors.redAccent,
                      size: 14,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      data.pcConnected ? 'Connected' : 'Not connected',
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                GestureDetector(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => SettingsScreen()),
                    );
                  },
                  child: const Text(
                    'Settings',
                    style: TextStyle(
                      color: Colors.white70,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _PrimaryButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: const Color(0xFF1D4ED8),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        onPressed: onTap,
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
    );
  }
}

class _SecondaryButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _SecondaryButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          side: const BorderSide(color: Colors.white70),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        onPressed: onTap,
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
    );
  }
}

class SessionHistoryScreen extends StatelessWidget {
  final ReferenceData data;

  const SessionHistoryScreen({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final sessions = data.mobileSessions;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Session History'),
        actions: [
          TextButton(onPressed: () {}, child: const Text('Export Session')),
        ],
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: sessions.length,
        itemBuilder: (context, index) {
          final session = sessions[index];
          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ActiveCaptureScreen(
                      sessionName: session.name,
                      status: CaptureStatus.zero(),
                    ),
                  ),
                );
              },
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                session.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 16,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                session.dateTime,
                                style: const TextStyle(
                                  color: Color(0xFF6B7280),
                                ),
                              ),
                            ],
                          ),
                        ),
                        StatusChip(
                          label: session.badge,
                          color: _badgeColor(session.badge),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        _MetaPill('${session.images} images'),
                        const SizedBox(width: 8),
                        _MetaPill('Pending: ${session.pending}'),
                        const SizedBox(width: 8),
                        _MetaPill('Temp: ${session.tempMode}'),
                      ],
                    ),
                    const SizedBox(height: 10),
                    TextButton(
                      onPressed: () {},
                      child: const Text('View Details'),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.all(16),
        child: ElevatedButton(
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => NewSessionFlow(data: data)),
            );
          },
          child: const Text('New Session'),
        ),
      ),
    );
  }
}

class _MetaPill extends StatelessWidget {
  final String text;
  const _MetaPill(this.text);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFF1E3A8A),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class NewSessionFlow extends StatefulWidget {
  final ReferenceData data;
  const NewSessionFlow({super.key, required this.data});

  @override
  State<NewSessionFlow> createState() => _NewSessionFlowState();
}

class _NewSessionFlowState extends State<NewSessionFlow> {
  int step = 0;
  final _nameController = TextEditingController();
  final _notesController = TextEditingController();
  String material = 'Aluminum';
  String captureMode = 'Manual Stills';
  double intervalSeconds = 5;
  String quality = 'High (Recommended)';
  String tempMode = 'Manual entry on demand';
  double promptInterval = 5;
  String promptType = 'Text prompt only';
  String tempUnit = '°C';
  String pairingTab = 'qr';
  String pairingCode = '';
  bool pairingConnected = false;
  String pairingStatus = 'Not connected';
  String? pairingError;
  bool pairingConnecting = false;
  WebSocketChannel? _pairingChannel;
  StreamSubscription? _pairingSub;
  bool _pairingTransferred = false;

  @override
  void dispose() {
    _nameController.dispose();
    _notesController.dispose();
    _pairingSub?.cancel();
    if (!_pairingTransferred) {
      _pairingChannel?.sink.close();
    }
    super.dispose();
  }

  void _next() {
    if (step < 4) {
      setState(() => step += 1);
    } else {
      final sessionTitle = _nameController.text.isEmpty
          ? 'New Session'
          : _nameController.text;
      final navigator = Navigator.of(context);
      _pairingTransferred = true;
      _pairingSub?.cancel();
      navigator.pushReplacement(
        MaterialPageRoute(
          builder: (_) => CameraAlignmentScreen(
            sessionName: sessionTitle,
            pairingChannel: _pairingChannel,
            onStart: () {
              navigator.pushReplacement(
                MaterialPageRoute(
                  builder: (_) => ActiveCaptureScreen(
                    sessionName: sessionTitle,
                    status: CaptureStatus.zero(),
                    pairingChannel: _pairingChannel,
                    showMonitorOnStart: true,
                  ),
                ),
              );
            },
          ),
        ),
      );
    }
  }

  void _back() {
    if (step == 0) {
      Navigator.pop(context);
    } else {
      setState(() => step -= 1);
    }
  }

  void _handlePairingCode(String code) {
    try {
      final raw = code.trim();
      Uri uri = Uri.parse(raw);
      String mode = uri.queryParameters['mode'] ?? 'live';
      String token = uri.queryParameters['token'] ?? '';

      // Support custom scheme `diffraction://pair?host=...`
      if (uri.scheme == 'diffraction') {
        final host = uri.queryParameters['host'] ?? uri.host;
        final port = int.tryParse(uri.queryParameters['port'] ?? '') ?? 8787;
        uri = Uri(
          scheme: 'ws',
          host: host,
          port: port,
          path: '/pair',
          queryParameters: {'token': token, 'mode': mode},
        );
      } else if (uri.scheme == 'http' || uri.scheme == 'https') {
        uri = uri.replace(scheme: uri.scheme == 'https' ? 'wss' : 'ws');
      }

      _connectWebSocket(uri, mode: mode, token: token, raw: raw);
    } catch (_) {
      setState(() {
        pairingConnected = false;
        pairingStatus = 'Not connected';
        pairingError =
            'Invalid code. Ensure QR encodes ws/http URL with host/token.';
      });
    }
  }

  Future<void> _connectWebSocket(
    Uri uri, {
    required String mode,
    required String token,
    required String raw,
  }) async {
    _pairingSub?.cancel();
    await _pairingChannel?.sink.close();
    if (!mounted) return;
    setState(() {
      pairingConnecting = true;
      pairingError = null;
      pairingStatus = 'Connecting to ${uri.host}:${uri.port}';
      pairingConnected = false;
    });
    try {
      final channel = WebSocketChannel.connect(uri);
      _pairingChannel = channel;
      _pairingSub = channel.stream.listen(
        (event) {
          if (!mounted) return;
          setState(() {
            pairingConnected = true;
            pairingConnecting = false;
            pairingStatus =
                'Connected to ${uri.host.isNotEmpty ? uri.host : raw} (${mode.toUpperCase()})';
          });
        },
        onError: (err) {
          if (!mounted) return;
          setState(() {
            pairingConnecting = false;
            pairingConnected = false;
            pairingError = 'Connection error: $err';
            pairingStatus = 'Not connected';
          });
        },
        onDone: () {
          if (!mounted) return;
          setState(() {
            pairingConnected = false;
            pairingConnecting = false;
            pairingStatus = 'Disconnected';
          });
        },
      );

      // Send a handshake payload.
      channel.sink.add(
        jsonEncode({
          'type': 'hello',
          'device': 'mobile',
          'mode': mode,
          'token': token,
          'session': _nameController.text.isEmpty
              ? 'New Session'
              : _nameController.text,
          'timestamp': DateTime.now().toIso8601String(),
        }),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        pairingConnecting = false;
        pairingConnected = false;
        pairingError = 'Failed to connect: $e';
        pairingStatus = 'Not connected';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final steps = [
      _BasicInfoStep(
        nameController: _nameController,
        notesController: _notesController,
        material: material,
        onMaterialChanged: (value) => setState(() => material = value),
      ),
      _CaptureSettingsStep(
        captureMode: captureMode,
        onCaptureModeChanged: (value) => setState(() => captureMode = value),
        intervalSeconds: intervalSeconds,
        onIntervalChanged: (value) => setState(() => intervalSeconds = value),
        quality: quality,
        onQualityChanged: (value) => setState(() => quality = value),
      ),
      _TempLoggingStep(
        tempMode: tempMode,
        onTempModeChanged: (value) => setState(() => tempMode = value),
        promptInterval: promptInterval,
        onPromptIntervalChanged: (value) =>
            setState(() => promptInterval = value),
        promptType: promptType,
        onPromptTypeChanged: (value) => setState(() => promptType = value),
        tempUnit: tempUnit,
        onTempUnitChanged: (value) => setState(() => tempUnit = value),
      ),
      _PairingStep(
        pairingTab: pairingTab,
        onTabChanged: (value) => setState(() => pairingTab = value),
        pairingCode: pairingCode,
        onCodeChanged: (value) => setState(() => pairingCode = value),
        onScan: _handlePairingCode,
        onTest: () => _handlePairingCode(pairingCode),
        statusText: pairingStatus,
        isConnected: pairingConnected,
        errorText: pairingError,
      ),
      const _TransferSetupStep(),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('New Session'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _back,
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _StepHeader(current: step, total: steps.length),
            const SizedBox(height: 12),
            Expanded(child: steps[step]),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _back,
                    child: const Text('Back'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _next,
                    child: Text(step == steps.length - 1 ? 'Next' : 'Next'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StepHeader extends StatelessWidget {
  final int current;
  final int total;
  const _StepHeader({required this.current, required this.total});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(
        total,
        (index) => Expanded(
          child: Container(
            height: 6,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: index <= current
                  ? const Color(0xFF2563EB)
                  : const Color(0xFFE5E7EB),
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ),
      ),
    );
  }
}

class _BasicInfoStep extends StatelessWidget {
  final TextEditingController nameController;
  final TextEditingController notesController;
  final String material;
  final ValueChanged<String> onMaterialChanged;

  const _BasicInfoStep({
    required this.nameController,
    required this.notesController,
    required this.material,
    required this.onMaterialChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Basic Info',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: nameController,
            decoration: const InputDecoration(
              labelText: 'Session Name',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: material,
            decoration: const InputDecoration(
              labelText: 'Material',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: 'Aluminum', child: Text('Aluminum')),
              DropdownMenuItem(value: 'Steel', child: Text('Steel')),
              DropdownMenuItem(value: 'Other', child: Text('Other')),
            ],
            onChanged: (value) {
              if (value != null) onMaterialChanged(value);
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: notesController,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Notes',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
    );
  }
}

class _CaptureSettingsStep extends StatelessWidget {
  final String captureMode;
  final ValueChanged<String> onCaptureModeChanged;
  final double intervalSeconds;
  final ValueChanged<double> onIntervalChanged;
  final String quality;
  final ValueChanged<String> onQualityChanged;

  const _CaptureSettingsStep({
    required this.captureMode,
    required this.onCaptureModeChanged,
    required this.intervalSeconds,
    required this.onIntervalChanged,
    required this.quality,
    required this.onQualityChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Capture Settings',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 16),
          RadioListTile<String>(
            value: 'Manual Stills',
            groupValue: captureMode,
            title: const Text('Manual Stills'),
            subtitle: const Text('Tap to capture each image'),
            onChanged: (value) => onCaptureModeChanged(value ?? ''),
          ),
          RadioListTile<String>(
            value: 'Timed Stills',
            groupValue: captureMode,
            title: const Text('Timed Stills'),
            subtitle: const Text('Capture at intervals'),
            onChanged: (value) => onCaptureModeChanged(value ?? ''),
          ),
          const SizedBox(height: 8),
          if (captureMode == 'Timed Stills') ...[
            const Text('Interval (seconds)'),
            Slider(
              value: intervalSeconds,
              min: 5,
              max: 60,
              divisions: 11,
              label: '${intervalSeconds.round()}s',
              onChanged: onIntervalChanged,
            ),
          ],
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            value: quality,
            decoration: const InputDecoration(
              labelText: 'Image Quality',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(
                value: 'High (Recommended)',
                child: Text('High (Recommended)'),
              ),
              DropdownMenuItem(value: 'Medium', child: Text('Medium')),
            ],
            onChanged: (value) => onQualityChanged(value ?? ''),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: 'JPG (Default)',
            decoration: const InputDecoration(
              labelText: 'Save Format',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(
                value: 'JPG (Default)',
                child: Text('JPG (Default)'),
              ),
            ],
            onChanged: (_) {},
          ),
        ],
      ),
    );
  }
}

class _TempLoggingStep extends StatelessWidget {
  final String tempMode;
  final ValueChanged<String> onTempModeChanged;
  final double promptInterval;
  final ValueChanged<double> onPromptIntervalChanged;
  final String promptType;
  final ValueChanged<String> onPromptTypeChanged;
  final String tempUnit;
  final ValueChanged<String> onTempUnitChanged;

  const _TempLoggingStep({
    required this.tempMode,
    required this.onTempModeChanged,
    required this.promptInterval,
    required this.onPromptIntervalChanged,
    required this.promptType,
    required this.onPromptTypeChanged,
    required this.tempUnit,
    required this.onTempUnitChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Temperature Logging',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 16),
          RadioListTile<String>(
            value: 'Manual entry on demand',
            groupValue: tempMode,
            title: const Text('Manual entry on demand'),
            onChanged: (value) => onTempModeChanged(value ?? ''),
          ),
          RadioListTile<String>(
            value: 'Prompt every N minutes',
            groupValue: tempMode,
            title: const Text('Prompt every N minutes'),
            onChanged: (value) => onTempModeChanged(value ?? ''),
          ),
          RadioListTile<String>(
            value: 'No temperature logging',
            groupValue: tempMode,
            title: const Text('No temperature logging'),
            onChanged: (value) => onTempModeChanged(value ?? ''),
          ),
          if (tempMode == 'Prompt every N minutes') ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Slider(
                    value: promptInterval,
                    min: 1,
                    max: 60,
                    divisions: 59,
                    label: '${promptInterval.round()} min',
                    onChanged: onPromptIntervalChanged,
                  ),
                ),
                SizedBox(
                  width: 70,
                  child: Text('${promptInterval.round()} min'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: promptType,
              decoration: const InputDecoration(
                labelText: 'Prompt type',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(
                  value: 'Text prompt only',
                  child: Text('Text prompt only'),
                ),
                DropdownMenuItem(
                  value: 'Voice prompt',
                  child: Text('Voice prompt (optional)'),
                ),
              ],
              onChanged: (value) => onPromptTypeChanged(value ?? ''),
            ),
          ],
          const SizedBox(height: 12),
          const Text('Temperature Units'),
          const SizedBox(height: 6),
          Row(
            children: [
              ChoiceChip(
                label: const Text('°F Fahrenheit'),
                selected: tempUnit == '°F',
                onSelected: (_) => onTempUnitChanged('°F'),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('°C Celsius'),
                selected: tempUnit == '°C',
                onSelected: (_) => onTempUnitChanged('°C'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PairingStep extends StatefulWidget {
  final String pairingTab;
  final ValueChanged<String> onTabChanged;
  final String pairingCode;
  final ValueChanged<String> onCodeChanged;
  final void Function(String code) onScan;
  final VoidCallback onTest;
  final String statusText;
  final String? errorText;
  final bool isConnected;

  const _PairingStep({
    required this.pairingTab,
    required this.onTabChanged,
    required this.pairingCode,
    required this.onCodeChanged,
    required this.onScan,
    required this.onTest,
    required this.statusText,
    required this.errorText,
    required this.isConnected,
  });

  @override
  State<_PairingStep> createState() => _PairingStepState();
}

class _PairingStepState extends State<_PairingStep> {
  final MobileScannerController _scannerController = MobileScannerController();
  bool _handledScan = false;

  @override
  void dispose() {
    _scannerController.dispose();
    super.dispose();
  }

  void _handleDetection(BarcodeCapture capture) {
    if (_handledScan) return;
    final code = capture.barcodes.first.rawValue;
    if (code == null || code.isEmpty) return;
    _handledScan = true;
    _scannerController.stop();
    widget.onScan(code);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'PC Pairing',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            _TabChip(
              label: 'Scan QR',
              selected: widget.pairingTab == 'qr',
              onTap: () => setState(() {
                _handledScan = false;
                _scannerController.start();
                widget.onTabChanged('qr');
              }),
            ),
            const SizedBox(width: 8),
            _TabChip(
              label: 'Enter Code',
              selected: widget.pairingTab == 'code',
              onTap: () {
                setState(() {
                  _handledScan = false;
                  widget.onTabChanged('code');
                });
              },
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (widget.pairingTab == 'qr')
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Stack(
                children: [
                  MobileScanner(
                    controller: _scannerController,
                    fit: BoxFit.cover,
                    onDetect: _handleDetection,
                  ),
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Colors.white.withAlpha((0.6 * 255).round()),
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (!_handledScan)
                    const Center(
                      child: Icon(
                        Icons.qr_code_scanner,
                        size: 72,
                        color: Colors.white70,
                      ),
                    ),
                ],
              ),
            ),
          )
        else
          TextField(
            decoration: const InputDecoration(
              labelText: 'Server URL / Code',
              border: OutlineInputBorder(),
            ),
            onChanged: widget.onCodeChanged,
          ),
        const SizedBox(height: 16),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: widget.isConnected
                ? const Color(0xFFEFFBF3)
                : const Color(0xFFFFF7E6),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: widget.isConnected
                  ? const Color(0xFF22C55E)
                  : const Color(0xFFF59E0B),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    widget.isConnected
                        ? Icons.check_circle
                        : Icons.info_outline,
                    color: widget.isConnected
                        ? const Color(0xFF22C55E)
                        : const Color(0xFFF59E0B),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.statusText,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
              if (widget.errorText != null) ...[
                const SizedBox(height: 6),
                Text(
                  widget.errorText!,
                  style: const TextStyle(color: Colors.red),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: widget.onTest,
                child: const Text('Test Connection'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextButton(
                onPressed: () {},
                child: const Text('Skip (Offline Mode)'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _TransferSetupStep extends StatelessWidget {
  const _TransferSetupStep();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: const [
        Text(
          'Transfer Setup',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        SizedBox(height: 12),
        Text('Ensure upload path exists before capture. Configure as needed.'),
      ],
    );
  }
}

class _TabChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _TabChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
    );
  }
}

class CameraAlignmentScreen extends StatefulWidget {
  final VoidCallback onStart;
  final String sessionName;
  final WebSocketChannel? pairingChannel;

  const CameraAlignmentScreen({
    super.key,
    required this.onStart,
    required this.sessionName,
    this.pairingChannel,
  });

  @override
  State<CameraAlignmentScreen> createState() => _CameraAlignmentScreenState();
}

class _CameraAlignmentScreenState extends State<CameraAlignmentScreen> {
  Rect? _dragRect;
  late final MobileScannerController _cameraController;
  bool _exposureLocked = false;
  bool _focusLocked = false;
  bool _whiteBalanceLocked = false;
  bool _startingSession = false;
  Size? _lastPreviewSize;

  @override
  void initState() {
    super.initState();
    _cameraController = MobileScannerController();
  }

  @override
  void dispose() {
    _cameraController.dispose();
    super.dispose();
  }

  void _resetRoi(RoiState state) {
    state.reset();
    setState(() {
      _dragRect = state.normalizedRect;
    });
  }

  void _updateRect(RoiState state, Rect rect) {
    state.updateRect(rect);
    setState(() {
      _dragRect = state.normalizedRect;
    });
  }

  void _toggleLock({bool? exposure, bool? focus, bool? whiteBalance}) {
    setState(() {
      if (exposure != null) _exposureLocked = exposure;
      if (focus != null) _focusLocked = focus;
      if (whiteBalance != null) _whiteBalanceLocked = whiteBalance;
    });

    if (widget.pairingChannel != null) {
      try {
        widget.pairingChannel!.sink.add(
          jsonEncode({
            'type': 'lock_update',
            'timestamp': DateTime.now().toIso8601String(),
            'session': widget.sessionName,
            'locks': {
              'exposure': _exposureLocked,
              'focus': _focusLocked,
              'whiteBalance': _whiteBalanceLocked,
            },
          }),
        );
      } catch (e) {
        debugPrint('Failed to send lock update: $e');
      }
    }
  }

  void _handleResize(
    DragUpdateDetails details,
    Size size,
    RoiState state, {
    bool left = false,
    bool right = false,
    bool top = false,
    bool bottom = false,
  }) {
    final current = _dragRect ?? state.normalizedRect;
    double l = current.left;
    double r = current.right;
    double t = current.top;
    double b = current.bottom;

    final dx = details.delta.dx / size.width;
    final dy = details.delta.dy / size.height;

    if (left) l += dx;
    if (right) r += dx;
    if (top) t += dy;
    if (bottom) b += dy;

    _updateRect(state, Rect.fromLTRB(l, t, r, b));
  }

  void _handleMove(DragUpdateDetails details, Size size, RoiState state) {
    final current = _dragRect ?? state.normalizedRect;
    final dx = details.delta.dx / size.width;
    final dy = details.delta.dy / size.height;
    _updateRect(
      state,
      Rect.fromLTWH(
        current.left + dx,
        current.top + dy,
        current.width,
        current.height,
      ),
    );
  }

  Future<void> _startSession(RoiState state) async {
    if (_startingSession) return;
    setState(() {
      _startingSession = true;
    });

    final previewSize = state.previewSize ?? const Size(1080, 1920);
    final roiPixels = state.pixelRectFor(previewSize);

    if (widget.pairingChannel != null) {
      try {
        widget.pairingChannel!.sink.add(
          jsonEncode({
            'type': 'session_start',
            'session': widget.sessionName,
            'timestamp': DateTime.now().toIso8601String(),
            'roi': {
              'normalized': {
                'left': state.normalizedRect.left,
                'top': state.normalizedRect.top,
                'width': state.normalizedRect.width,
                'height': state.normalizedRect.height,
              },
              'pixels': {
                'x': roiPixels.left,
                'y': roiPixels.top,
                'width': roiPixels.width,
                'height': roiPixels.height,
              },
              'previewSize': {
                'width': previewSize.width,
                'height': previewSize.height,
              },
            },
            'locks': {
              'exposure': _exposureLocked,
              'focus': _focusLocked,
              'whiteBalance': _whiteBalanceLocked,
            },
          }),
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Session started and sent to desktop'),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to notify desktop: $e')),
          );
        }
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Starting locally (no desktop pairing)'),
          ),
        );
      }
    }

    if (mounted) {
      setState(() {
        _startingSession = false;
      });
      widget.onStart();
    }
  }

  Widget _handleAt(
    Offset position,
    Size size,
    RoiState state, {
    bool left = false,
    bool right = false,
    bool top = false,
    bool bottom = false,
  }) {
    const double handleSize = 18;
    return Positioned(
      left: position.dx - handleSize / 2,
      top: position.dy - handleSize / 2,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanUpdate: (details) => _handleResize(
          details,
          size,
          state,
          left: left,
          right: right,
          top: top,
          bottom: bottom,
        ),
        child: Container(
          width: handleSize,
          height: handleSize,
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: Colors.blue.shade400, width: 2),
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final roiState = RoiProvider.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Camera Alignment / ROI'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final size = Size(
                      constraints.maxWidth,
                      constraints.maxHeight,
                    );
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      if (_lastPreviewSize == size) return;
                      _lastPreviewSize = size;
                      roiState.updatePreviewSize(size);
                    });
                    final normalized = _dragRect ?? roiState.normalizedRect;
                    final roiPixels = Rect.fromLTWH(
                      normalized.left * size.width,
                      normalized.top * size.height,
                      normalized.width * size.width,
                      normalized.height * size.height,
                    );

                    return Stack(
                      children: [
                        MobileScanner(
                          controller: _cameraController,
                          fit: BoxFit.cover,
                          onDetect: (_) {},
                        ),
                        Positioned.fill(
                          child: Container(
                            color: Colors.black.withAlpha((0.15 * 255).round()),
                          ),
                        ),
                        Positioned(
                          left: roiPixels.left,
                          top: roiPixels.top,
                          width: roiPixels.width,
                          height: roiPixels.height,
                          child: GestureDetector(
                            onPanUpdate: (details) =>
                                _handleMove(details, size, roiState),
                            child: Container(
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: Colors.blueAccent,
                                  width: 3,
                                ),
                                color: Colors.white.withAlpha((0.08 * 255).round()),
                              ),
                            ),
                          ),
                        ),
                        _handleAt(
                          roiPixels.topLeft,
                          size,
                          roiState,
                          left: true,
                          top: true,
                        ),
                        _handleAt(
                          roiPixels.topRight,
                          size,
                          roiState,
                          right: true,
                          top: true,
                        ),
                        _handleAt(
                          roiPixels.bottomLeft,
                          size,
                          roiState,
                          left: true,
                          bottom: true,
                        ),
                        _handleAt(
                          roiPixels.bottomRight,
                          size,
                          roiState,
                          right: true,
                          bottom: true,
                        ),
                        Positioned(
                          top: 12,
                          left: 12,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.6),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'ROI ${roiPixels.width.toStringAsFixed(0)} x ${roiPixels.height.toStringAsFixed(0)} px',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                Text(
                                  'x:${roiPixels.left.toStringAsFixed(0)}  y:${roiPixels.top.toStringAsFixed(0)}',
                                  style: const TextStyle(color: Colors.white70),
                                ),
                                Text(
                                  'Session: ${widget.sessionName}',
                                  style: const TextStyle(color: Colors.white70),
                                ),
                                Text(
                                  widget.pairingChannel != null
                                      ? 'Desktop link ready'
                                      : 'Not paired to desktop',
                                  style: TextStyle(
                                    color: widget.pairingChannel != null
                                        ? Colors.lightGreenAccent
                                        : Colors.orangeAccent,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        Positioned(
                          bottom: 12,
                          left: 12,
                          child: Row(
                            children: [
                              const Icon(
                                Icons.brightness_6,
                                color: Colors.white70,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _exposureLocked
                                    ? 'Exposure locked'
                                    : 'Brightness OK',
                                style: const TextStyle(color: Colors.white70),
                              ),
                            ],
                          ),
                        ),
                        Positioned(
                          bottom: 12,
                          right: 12,
                          child: Row(
                            children: [
                              Icon(
                                _focusLocked
                                    ? Icons.center_focus_weak_outlined
                                    : Icons.center_focus_strong,
                                color: Colors.white70,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _focusLocked ? 'Focus locked' : 'Sharpness OK',
                                style: const TextStyle(color: Colors.white70),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilterChip(
                  label: const Text('Lock exposure'),
                  selected: _exposureLocked,
                  onSelected: (value) {
                    _toggleLock(exposure: value);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          value ? 'Exposure locked' : 'Exposure auto adjusts',
                        ),
                      ),
                    );
                  },
                ),
                FilterChip(
                  label: const Text('Lock focus'),
                  selected: _focusLocked,
                  onSelected: (value) {
                    _toggleLock(focus: value);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          value ? 'Focus locked' : 'Focus auto adjusts',
                        ),
                      ),
                    );
                  },
                ),
                FilterChip(
                  label: const Text('Lock white balance'),
                  selected: _whiteBalanceLocked,
                  onSelected: (value) {
                    _toggleLock(whiteBalance: value);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          value
                              ? 'White balance locked'
                              : 'White balance auto adjusts',
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _resetRoi(roiState),
                    child: const Text('Reset ROI'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _startingSession
                        ? null
                        : () async {
                            await _startSession(roiState);
                          },
                    child: _startingSession
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Start Session'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class CaptureStatus {
  final int captured;
  final int pending;
  final int uploaded;
  const CaptureStatus({
    required this.captured,
    required this.pending,
    required this.uploaded,
  });
  factory CaptureStatus.zero() =>
      const CaptureStatus(captured: 0, pending: 0, uploaded: 0);
}

class ActiveCaptureScreen extends StatefulWidget {
  final String sessionName;
  final CaptureStatus status;
  final WebSocketChannel? pairingChannel;
  final bool showMonitorOnStart;

  const ActiveCaptureScreen({
    super.key,
    required this.sessionName,
    required this.status,
    this.pairingChannel,
    this.showMonitorOnStart = false,
  });

  @override
  State<ActiveCaptureScreen> createState() => _ActiveCaptureScreenState();
}

class _ActiveCaptureScreenState extends State<ActiveCaptureScreen> {
  final GlobalKey _roiPreviewKey = GlobalKey();
  CameraController? _sessionCameraController;
  Future<void>? _cameraInitFuture;
  String? _lastSendSummary;
  bool _temperatureLocked = false;
  String? _temperatureValue;
  bool _mutePrompts = false;
  bool _isSending = false;
  bool _timedWindowBusy = false;
  final List<Map<String, dynamic>> _queuedFrames = [];
  final Duration _timedInterval = const Duration(seconds: 8);
  final ValueNotifier<List<_CapturedPhoto>> _capturedPhotos =
      ValueNotifier<List<_CapturedPhoto>>([]);
  late final ValueNotifier<_MonitorStatus> _monitorStatus;
  bool _monitorOpen = false;
  Size? _lastPreviewSize;
  late final bool _livePreviewSupported;
  bool _cameraInitFailed = false;

  @override
  void dispose() {
    widget.pairingChannel?.sink.close();
    _capturedPhotos.dispose();
    _monitorStatus.dispose();
    _sessionCameraController?.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _livePreviewSupported = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    _monitorStatus = ValueNotifier<_MonitorStatus>(
      _MonitorStatus(
        connected: widget.pairingChannel != null,
        temperatureLocked: _temperatureLocked,
        queuedFrames: _queuedFrames.length,
      ),
    );
    if (_livePreviewSupported) {
      _cameraInitFuture = _initSessionCamera();
    }
    if (widget.showMonitorOnStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final roiState = RoiProvider.of(context);
        _openTimedCaptureWindow(roiState);
      });
    }
  }

  Future<void> _initSessionCamera() async {
    try {
      final cameras = await availableCameras();
      if (!mounted || cameras.isEmpty) return;
      final backCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        backCamera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      _sessionCameraController = controller;
      await controller.initialize();
      if (!mounted) return;
      setState(() => _cameraInitFailed = false);
    } catch (_) {
      if (!mounted) return;
      setState(() => _cameraInitFailed = true);
    }
  }

  Future<void> _sendCapture(RoiState roiState) async {
    if (_isSending) return;
    if (!mounted) return;
    setState(() => _isSending = true);
    final size = roiState.previewSize ?? const Size(1080, 1920);
    final roiPixels = roiState.pixelRectFor(size);
    final frameBytes = await _captureRoiFrame(roiState);
    if (!mounted) return;

    final payload = {
      'type': 'frame',
      'session': widget.sessionName,
      'timestamp': DateTime.now().toIso8601String(),
      'roi': {
        'normalized': {
          'left': roiState.normalizedRect.left,
          'top': roiState.normalizedRect.top,
          'width': roiState.normalizedRect.width,
          'height': roiState.normalizedRect.height,
        },
        'pixels': {
          'x': roiPixels.left,
          'y': roiPixels.top,
          'width': roiPixels.width,
          'height': roiPixels.height,
        },
        'previewSize': {'width': size.width, 'height': size.height},
      },
      'frame': base64Encode(frameBytes),
    };

    _recordCapture(frameBytes, roiPixels);

    final connected = widget.pairingChannel != null;

    if (!_temperatureLocked || !connected) {
      if (!mounted) return;
      setState(() {
        _queuedFrames.add(payload);
        _isSending = false;
      });
      _updateMonitorStatus();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _temperatureLocked
                  ? 'Desktop offline. Queued photo for later.'
                  : 'Awaiting temperature lock before sending. Queued photo.',
            ),
          ),
        );
      }
      return;
    }

    await _sendCaptureToDesktop(payload, roiPixels: roiPixels);
    if (!mounted) return;
    setState(() => _isSending = false);
  }

  void _flushQueue() {
    if (widget.pairingChannel == null || !_temperatureLocked) return;
    for (final payload in List<Map<String, dynamic>>.from(_queuedFrames)) {
      _sendCaptureToDesktop(payload);
    }
    setState(() => _queuedFrames.clear());
    _updateMonitorStatus();
    if (mounted && _queuedFrames.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Queued frames sent to desktop.')),
      );
    }
  }

  Future<Uint8List> _captureRoiFrame(RoiState roiState) async {
    final normalized = roiState.normalizedRect;
    final controller = _sessionCameraController;

    if (_livePreviewSupported &&
        controller != null &&
        controller.value.isInitialized) {
      try {
        final file = await controller.takePicture();
        final bytes = await file.readAsBytes();
        final image = await decodeImageFromList(bytes);
        final roiRect = Rect.fromLTWH(
          normalized.left * image.width,
          normalized.top * image.height,
          normalized.width * image.width,
          normalized.height * image.height,
        );

        final recorder = PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawImageRect(
          image,
          roiRect,
          Rect.fromLTWH(0, 0, roiRect.width, roiRect.height),
          Paint(),
        );

        final cropped = await recorder.endRecording().toImage(
          max(1, roiRect.width.round()),
          max(1, roiRect.height.round()),
        );
        final data = await cropped.toByteData(format: ImageByteFormat.png);
        if (data != null) {
          return data.buffer.asUint8List();
        }
      } catch (_) {}
    }

    final size = roiState.previewSize ?? const Size(1080, 1920);
    final fallbackRoi = roiState.pixelRectFor(size);
    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);
    final width = max(1, size.width.round());
    final height = max(1, size.height.round());

    final gradient = const LinearGradient(
      colors: [Color(0xFF0EA5E9), Color(0xFF1D4ED8)],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ).createShader(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()));

    canvas.drawRect(
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..shader = gradient,
    );
    canvas.drawRect(
      fallbackRoi,
      Paint()..color = Colors.white.withAlpha((0.2 * 255).round()),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(fallbackRoi, const Radius.circular(8)),
      Paint()
        ..color = Colors.white.withAlpha((0.4 * 255).round())
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4,
    );

    final label = TextPainter(
      text: TextSpan(
        text:
            '${fallbackRoi.width.toStringAsFixed(0)} x ${fallbackRoi.height.toStringAsFixed(0)} @ (${fallbackRoi.left.toStringAsFixed(0)}, ${fallbackRoi.top.toStringAsFixed(0)})',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width - 24);
    label.paint(canvas, Offset(12, 12));

    final image = await recorder.endRecording().toImage(width, height);
    final data = await image.toByteData(format: ImageByteFormat.png);
    return data?.buffer.asUint8List() ?? Uint8List(0);
  }

  Widget _buildGradientPlaceholder() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF0EA5E9), Color(0xFF1D4ED8)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
    );
  }

  Future<void> _promptTemperature() async {
    final entered = await Navigator.push<String?>(
      context,
      MaterialPageRoute(builder: (_) => TemperatureEntryScreen()),
    );
    if (!mounted) return;
    if (entered == null || entered.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Temperature required before sending frames.'),
          ),
        );
      }
      return;
    }
    setState(() {
      _temperatureLocked = true;
      _temperatureValue = entered.trim();
    });
    _updateMonitorStatus();
    if (widget.pairingChannel != null) {
      widget.pairingChannel?.sink.add(
        jsonEncode({
          'type': 'temperature',
          'value': entered.trim(),
          'timestamp': DateTime.now().toIso8601String(),
        }),
      );
    }
    _flushQueue();
  }

  void _recordCapture(Uint8List bytes, Rect roi) {
    final updated = [
      _CapturedPhoto(
        bytes: bytes,
        createdAt: DateTime.now(),
        summary:
            '${roi.width.toStringAsFixed(0)}x${roi.height.toStringAsFixed(0)} @ (${roi.left.toStringAsFixed(0)}, ${roi.top.toStringAsFixed(0)})',
      ),
      ..._capturedPhotos.value,
    ];
    _capturedPhotos.value = updated.take(12).toList();
    _updateMonitorStatus();
  }

  void _openTimedCaptureWindow(RoiState roiState) {
    if (_monitorOpen) return;
    if (!mounted) return;

    final nav = Navigator.of(context, rootNavigator: true);
    final messenger = ScaffoldMessenger.of(context);
    _monitorOpen = true;
    showDialog(
      context: nav.context,
      builder: (_) => TimedCaptureWindow(
        photos: _capturedPhotos,
        interval: _timedInterval,
        status: _monitorStatus,
        onClose: () {
          _monitorOpen = false;
          nav.pop();
        },
        onCapture: () => _sendCapture(roiState),
      ),
    ).then((_) {
      _monitorOpen = false;
      if (mounted) {
        messenger.clearSnackBars();
      }
    });
  }

  Future<void> _sendCaptureToDesktop(
    Map<String, dynamic> payload, {
    Rect? roiPixels,
  }) async {
    try {
      widget.pairingChannel?.sink.add(jsonEncode(payload));
      if (!mounted) return;
      setState(() {
        if (roiPixels != null) {
          _lastSendSummary =
              'Sent ROI ${roiPixels.width.toStringAsFixed(0)}x${roiPixels.height.toStringAsFixed(0)} at (${roiPixels.left.toStringAsFixed(0)}, ${roiPixels.top.toStringAsFixed(0)})';
        }
      });
      _updateMonitorStatus();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Capture sent with ROI metadata')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to send capture: $e')));
    }
  }

  void _updateMonitorStatus() {
    _monitorStatus.value = _monitorStatus.value.copyWith(
      temperatureLocked: _temperatureLocked,
      queuedFrames: _queuedFrames.length,
    );
  }

  @override
  Widget build(BuildContext context) {
    final roiState = RoiProvider.of(context);
    final connected = widget.pairingChannel != null;

    if (connected && _temperatureLocked && _queuedFrames.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _flushQueue());
    }
    return WillPopScope(
      onWillPop: () async {
        final proceed =
            await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Session running'),
                content: const Text(
                  'Stop the session before leaving to avoid losing queued captures.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Stay'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('End Anyway'),
                  ),
                ],
              ),
            ) ??
            false;
        return proceed;
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.sessionName),
          actions: [
            IconButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      UploadQueueScreen(status: widget.status, items: const []),
                ),
              ),
              icon: const Icon(Icons.cloud_upload_outlined),
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.circle,
                    color: connected ? Colors.green : Colors.red,
                    size: 12,
                  ),
                  const SizedBox(width: 6),
                  Text(connected ? 'Connected to desktop' : 'Not connected'),
                  const Spacer(),
                  Row(
                    children: [
                      IconButton(
                        onPressed: () =>
                            setState(() => _mutePrompts = !_mutePrompts),
                        icon: Icon(_mutePrompts ? Icons.mic_off : Icons.mic),
                      ),
                      const Text('00:00:00'),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final size = Size(
                        constraints.maxWidth,
                        constraints.maxHeight,
                      );
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (!mounted) return;
                        if (_lastPreviewSize == size) return;
                        _lastPreviewSize = size;
                        roiState.updatePreviewSize(size);
                      });
                      final roiPixels = roiState.pixelRectFor(size);
                      return RepaintBoundary(
                        key: _roiPreviewKey,
                        child: ValueListenableBuilder<PairingServerState>(
                          valueListenable: PairingHost.instance.state,
                          builder: (context, pairingState, _) {
                            final background = _livePreviewSupported
                                ? FutureBuilder<void>(
                                    future: _cameraInitFuture,
                                    builder: (context, snapshot) {
                                      if (snapshot.connectionState ==
                                          ConnectionState.waiting) {
                                        return const Center(
                                          child: CircularProgressIndicator(),
                                        );
                                      }
                                      if (_cameraInitFailed ||
                                          _sessionCameraController == null) {
                                        return _buildGradientPlaceholder();
                                      }
                                      return CameraPreview(
                                        _sessionCameraController!,
                                      );
                                    },
                                  )
                                : pairingState.lastFrameBytes != null
                                ? Image.memory(
                                    pairingState.lastFrameBytes!,
                                    fit: BoxFit.cover,
                                    gaplessPlayback: true,
                                    width: size.width,
                                    height: size.height,
                                  )
                                : _buildGradientPlaceholder();

                            return Stack(
                              children: [
                                Positioned.fill(child: background),
                                Positioned(
                                  left: roiPixels.left,
                                  top: roiPixels.top,
                                  width: roiPixels.width,
                                  height: roiPixels.height,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                        color: Colors.blueAccent,
                                        width: 3,
                                      ),
                                      color: Colors.white.withAlpha((0.05 * 255).round()),
                                    ),
                                  ),
                                ),
                                Positioned(
                                  top: 12,
                                  right: 12,
                                  child: Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withAlpha((0.6 * 255).round()),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'ROI ${roiPixels.width.toStringAsFixed(0)}x${roiPixels.height.toStringAsFixed(0)}',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        Text(
                                          'x:${roiPixels.left.toStringAsFixed(0)} y:${roiPixels.top.toStringAsFixed(0)}',
                                          style: const TextStyle(
                                            color: Colors.white70,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _temperatureLocked
                      ? const Color(0xFFF0FDF4)
                      : const Color(0xFFFFF7ED),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _temperatureLocked
                        ? const Color(0xFF22C55E)
                        : const Color(0xFFF97316),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      _temperatureLocked
                          ? Icons.thermostat
                          : Icons.warning_amber_rounded,
                      color: _temperatureLocked
                          ? const Color(0xFF16A34A)
                          : const Color(0xFFD97706),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _temperatureLocked
                                ? 'Temperature locked at ${_temperatureValue ?? '--'} °C'
                                : 'Lock temperature before captures sync to desktop.',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          Text(
                            _queuedFrames.isEmpty
                                ? 'Frames go live as soon as you capture.'
                                : '${_queuedFrames.length} capture(s) queued until temperature is locked and desktop is ready.',
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton(
                      onPressed: _promptTemperature,
                      child: Text(
                        _temperatureLocked ? 'Update Temp' : 'Enter Temp',
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ElevatedButton.icon(
                    onPressed: connected && _temperatureLocked
                        ? () => _sendCapture(roiState)
                        : null,
                    icon: const Icon(Icons.camera_alt_outlined),
                    label: const Text('Capture Now'),
                  ),
                  OutlinedButton.icon(
                    onPressed: connected && _temperatureLocked
                        ? () async {
                            if (_timedWindowBusy) return;
                            _timedWindowBusy = true;
                            try {
                              if (!mounted) return;
                              _openTimedCaptureWindow(roiState);
                            } finally {
                              if (mounted) {
                                _timedWindowBusy = false;
                              }
                            }
                          }
                        : null,
                    icon: const Icon(Icons.timer),
                    label: const Text('Start Timed Capture'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _promptTemperature,
                    icon: const Icon(Icons.thermostat),
                    label: const Text('Enter Temperature'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () {},
                    icon: const Icon(Icons.flag),
                    label: const Text('Mark Last Capture as Bad'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () {},
                    icon: const Icon(Icons.note_add_outlined),
                    label: const Text('Add Note'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_lastSendSummary != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    children: [
                      const Icon(Icons.check_circle, color: Colors.green),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_lastSendSummary!)),
                    ],
                  ),
                ),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _UploadStat(
                      label: 'Captured',
                      value: widget.status.captured,
                    ),
                    _UploadStat(label: 'Pending', value: widget.status.pending),
                    _UploadStat(
                      label: 'Uploaded',
                      value: widget.status.uploaded,
                    ),
                    TextButton(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => UploadQueueScreen(
                              status: widget.status,
                              items: const [],
                            ),
                          ),
                        );
                      },
                      child: const Text('View Upload Queue'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {},
                      child: const Text('Pause Session'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                SessionSummaryScreen(status: widget.status),
                          ),
                        );
                      },
                      child: const Text('End Session'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UploadStat extends StatelessWidget {
  final String label;
  final int value;
  const _UploadStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value.toString(),
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
        ),
        Text(label),
      ],
    );
  }
}

class _CapturedPhoto {
  final Uint8List bytes;
  final DateTime createdAt;
  final String summary;

  const _CapturedPhoto({
    required this.bytes,
    required this.createdAt,
    required this.summary,
  });

  String get timestampLabel {
    final time = createdAt.toLocal();
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    final second = time.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }
}

class _MonitorStatus {
  final bool connected;
  final bool temperatureLocked;
  final int queuedFrames;

  const _MonitorStatus({
    required this.connected,
    required this.temperatureLocked,
    required this.queuedFrames,
  });

  _MonitorStatus copyWith({
    bool? connected,
    bool? temperatureLocked,
    int? queuedFrames,
  }) {
    return _MonitorStatus(
      connected: connected ?? this.connected,
      temperatureLocked: temperatureLocked ?? this.temperatureLocked,
      queuedFrames: queuedFrames ?? this.queuedFrames,
    );
  }
}

class _MonitorStatusChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _MonitorStatusChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
        color: color.withAlpha((0.12 * 255).round()),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withAlpha((0.4 * 255).round())),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class TimedCaptureWindow extends StatefulWidget {
  final ValueNotifier<List<_CapturedPhoto>> photos;
  final Duration interval;
  final ValueListenable<_MonitorStatus> status;
  final Future<void> Function() onCapture;
  final VoidCallback onClose;

  const TimedCaptureWindow({
    super.key,
    required this.photos,
    required this.interval,
    required this.status,
    required this.onCapture,
    required this.onClose,
  });

  @override
  State<TimedCaptureWindow> createState() => _TimedCaptureWindowState();
}

class _TimedCaptureWindowState extends State<TimedCaptureWindow> {
  Timer? _timer;
  int _secondsRemaining = 0;
  bool _captureInFlight = false;
  bool _running = true;

  @override
  void initState() {
    super.initState();
    _secondsRemaining = widget.interval.inSeconds;
    _startTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  Future<void> _tick() async {
    if (!mounted) return;
    if (!_running) return;
    if (_secondsRemaining <= 1) {
      await _triggerCapture();
      if (!mounted) return;
      return;
    }
    if (!mounted) return;
    setState(() => _secondsRemaining -= 1);
  }

  Future<void> _triggerCapture() async {
    if (!mounted || _captureInFlight) return;
    setState(() {
      _captureInFlight = true;
      _secondsRemaining = widget.interval.inSeconds;
    });
    try {
      await widget.onCapture();
    } finally {
      if (!mounted) return;
      setState(() => _captureInFlight = false);
    }
  }

  void _toggleRunning() {
    setState(() {
      _running = !_running;
    });
    if (_running) {
      _startTimer();
      setState(() => _secondsRemaining = widget.interval.inSeconds);
    } else {
      _timer?.cancel();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 520),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text(
                    'Timed Capture Monitor',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              ValueListenableBuilder<_MonitorStatus>(
                valueListenable: widget.status,
                builder: (context, status, _) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Live status',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _MonitorStatusChip(
                            icon: status.connected
                                ? Icons.desktop_windows_outlined
                                : Icons.desktop_access_disabled,
                            label: status.connected
                                ? 'Desktop link ready'
                                : 'Desktop offline',
                            color: status.connected
                                ? const Color(0xFF16A34A)
                                : const Color(0xFFF97316),
                          ),
                          _MonitorStatusChip(
                            icon: status.temperatureLocked
                                ? Icons.thermostat
                                : Icons.thermostat_auto_outlined,
                            label: status.temperatureLocked
                                ? 'Temperature locked'
                                : 'Waiting for temperature lock',
                            color: status.temperatureLocked
                                ? const Color(0xFF0EA5E9)
                                : const Color(0xFFE11D48),
                          ),
                          _MonitorStatusChip(
                            icon: status.queuedFrames > 0
                                ? Icons.schedule_send
                                : Icons.check_circle_outline,
                            label: status.queuedFrames > 0
                                ? '${status.queuedFrames} capture(s) queued'
                                : 'All captures delivered',
                            color: status.queuedFrames > 0
                                ? const Color(0xFFF59E0B)
                                : const Color(0xFF16A34A),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Next photo in',
                      style: TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '$_secondsRemaining',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 48,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'seconds',
                          style: TextStyle(color: Colors.white70, fontSize: 16),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Interval: ${widget.interval.inSeconds}s • ${_running ? 'Running' : 'Paused'}',
                      style: const TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        ElevatedButton.icon(
                          onPressed: _captureInFlight ? null : _triggerCapture,
                          icon: const Icon(Icons.camera),
                          label: const Text('Capture now'),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _toggleRunning,
                            icon: Icon(
                              _running ? Icons.pause : Icons.play_arrow,
                            ),
                            label: Text(
                              _running ? 'Pause countdown' : 'Resume countdown',
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Recent photos',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ValueListenableBuilder<List<_CapturedPhoto>>(
                  valueListenable: widget.photos,
                  builder: (context, items, _) {
                    if (items.isEmpty) {
                      return const Center(
                        child: Text('No photos captured yet.'),
                      );
                    }
                    return ListView.separated(
                      itemCount: items.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final photo = items[index];
                        return Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF8FAFC),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFFE2E8F0)),
                          ),
                          child: Row(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: Image.memory(
                                  photo.bytes,
                                  width: 72,
                                  height: 72,
                                  fit: BoxFit.cover,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Captured at ${photo.timestampLabel}',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 15,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      photo.summary,
                                      style: const TextStyle(
                                        color: Color(0xFF475569),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class TemperatureEntryScreen extends StatefulWidget {
  TemperatureEntryScreen({super.key});

  @override
  State<TemperatureEntryScreen> createState() => _TemperatureEntryScreenState();
}

class _TemperatureEntryScreenState extends State<TemperatureEntryScreen> {
  final _tempController = TextEditingController();
  final _noteController = TextEditingController();
  bool _muteVoice = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Enter Temperature')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _tempController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Temperature value',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              decoration: const InputDecoration(
                labelText: 'Timestamp (auto)',
                border: OutlineInputBorder(),
              ),
              readOnly: true,
              controller: TextEditingController(
                text: DateTime.now().toString(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _noteController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Note (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              value: _muteVoice,
              onChanged: (value) => setState(() => _muteVoice = value),
              title: const Text(
                'Silence voice prompts while entering temperature',
              ),
              secondary: Icon(
                _muteVoice ? Icons.volume_off : Icons.volume_up_outlined,
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () =>
                        Navigator.pop(context, _tempController.text),
                    child: const Text('Save'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class UploadQueueScreen extends StatelessWidget {
  final CaptureStatus status;
  final List<UploadItem> items;

  const UploadQueueScreen({
    super.key,
    required this.status,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    final displayItems = items.isEmpty
        ? [
            const UploadItem(
              fileName: 'IMG_0001.jpg',
              capturedAt: '--',
              status: 'Pending',
              retries: 0,
            ),
            const UploadItem(
              fileName: 'IMG_0002.jpg',
              capturedAt: '--',
              status: 'Failed',
              retries: 1,
            ),
          ]
        : items;

    return Scaffold(
      appBar: AppBar(title: const Text('Upload Queue')),
      body: ListView.builder(
        itemCount: displayItems.length,
        itemBuilder: (context, index) {
          final item = displayItems[index];
          return ListTile(
            leading: Icon(
              Icons.insert_drive_file_outlined,
              color: _badgeColor(item.status),
            ),
            title: Text(item.fileName),
            subtitle: Text(
              'Captured: ${item.capturedAt} • Retries: ${item.retries}',
            ),
            trailing: StatusChip(
              label: item.status,
              color: _badgeColor(item.status),
            ),
            onTap: () {},
          );
        },
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () {},
                child: const Text('Retry failed'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton(
                onPressed: () {},
                child: const Text('Resume uploads'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SessionSummaryScreen extends StatelessWidget {
  final CaptureStatus status;
  const SessionSummaryScreen({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Session Summary')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SummaryCard(title: 'Total images', value: status.captured),
            _SummaryCard(title: 'Temp entries', value: 0),
            _SummaryCard(
              title: 'Upload completeness',
              value: '${status.uploaded}/${status.captured}',
            ),
            const _SummaryCard(title: 'Notes', value: 'None'),
            const Spacer(),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Return to Home'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Finalize Session'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final String title;
  final Object value;
  const _SummaryCard({required this.title, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(color: Color(0xFF6B7280))),
          const SizedBox(height: 4),
          Text(
            '$value',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
          ),
        ],
      ),
    );
  }
}

class SettingsScreen extends StatefulWidget {
  SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool autoDelete = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Auto-delete after upload'),
            value: autoDelete,
            onChanged: (value) => setState(() => autoDelete = value),
          ),
          ListTile(
            title: const Text('Default capture interval'),
            subtitle: const Text('10s'),
            onTap: () {},
          ),
          ListTile(
            title: const Text('Default temp unit'),
            subtitle: const Text('°C'),
            onTap: () {},
          ),
          ListTile(
            title: const Text('Default pairing method'),
            subtitle: const Text('Scan QR'),
            onTap: () {},
          ),
          ListTile(
            title: const Text('Storage location'),
            subtitle: const Text('Local device'),
            onTap: () {},
          ),
          ListTile(
            title: const Text('Debug logs'),
            trailing: Switch(value: false, onChanged: (_) {}),
          ),
          ListTile(title: const Text('Reset all settings'), onTap: () {}),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Data models + loader
// ---------------------------------------------------------------------------

class ReferenceData {
  final List<ProjectData> projects;
  final List<SessionData> sessions;
  final Stats stats;
  final List<MobileSessionData> mobileSessions;
  final List<UploadItem> uploadItems;
  final bool pcConnected;
  final String? lastSession;

  const ReferenceData({
    required this.projects,
    required this.sessions,
    required this.stats,
    required this.mobileSessions,
    required this.uploadItems,
    required this.pcConnected,
    required this.lastSession,
  });

  factory ReferenceData.fromJson(Map<String, dynamic> json) {
    return ReferenceData(
      projects: (json['projects'] as List<dynamic>? ?? [])
          .map((p) => ProjectData.fromJson(p as Map<String, dynamic>))
          .toList(),
      sessions: (json['sessions'] as List<dynamic>? ?? [])
          .map((s) => SessionData.fromJson(s as Map<String, dynamic>))
          .toList(),
      stats: Stats.fromJson(json['stats'] as Map<String, dynamic>? ?? {}),
      mobileSessions: (json['mobileSessions'] as List<dynamic>? ?? [])
          .map((s) => MobileSessionData.fromJson(s as Map<String, dynamic>))
          .toList(),
      uploadItems: (json['uploadQueue'] as List<dynamic>? ?? [])
          .map((u) => UploadItem.fromJson(u as Map<String, dynamic>))
          .toList(),
      pcConnected: json['pcConnection'] as bool? ?? false,
      lastSession: json['lastSession'] as String?,
    );
  }

  factory ReferenceData.empty() {
    return const ReferenceData(
      projects: [],
      sessions: [],
      stats: Stats(projects: 0, sessions: 0, images: 0, temps: 0),
      mobileSessions: [],
      uploadItems: [],
      pcConnected: false,
      lastSession: null,
    );
  }
}

class ReferenceDataLoader {
  static Future<ReferenceData> load() async {
    try {
      final jsonStr = await rootBundle.loadString('assets/reference_data.json');
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      return ReferenceData.fromJson(data);
    } catch (_) {
      return ReferenceData.empty();
    }
  }
}

class ProjectData {
  final String name;
  final int sessions;
  final bool isActive;

  const ProjectData({
    required this.name,
    required this.sessions,
    required this.isActive,
  });

  factory ProjectData.fromJson(Map<String, dynamic> json) {
    return ProjectData(
      name: (json['name'] as String?) ?? 'Project',
      sessions: (json['sessions'] as num?)?.toInt() ?? 0,
      isActive: (json['active'] as bool?) ?? false,
    );
  }

  ProjectData copyWith({String? name, int? sessions, bool? isActive}) {
    return ProjectData(
      name: name ?? this.name,
      sessions: sessions ?? this.sessions,
      isActive: isActive ?? this.isActive,
    );
  }
}

class SessionData {
  final String title;
  final String date;
  final int images;
  final int temps;
  final String status;
  final Color statusColor;
  final IconData icon;
  final Color iconColor;

  const SessionData({
    required this.title,
    required this.date,
    required this.images,
    required this.temps,
    required this.status,
    required this.statusColor,
    required this.icon,
    required this.iconColor,
  });

  factory SessionData.fromJson(Map<String, dynamic> json) {
    return SessionData(
      title: (json['title'] as String?) ?? 'Session',
      date: (json['date'] as String?) ?? '',
      images: (json['images'] as num?)?.toInt() ?? 0,
      temps: (json['temps'] as num?)?.toInt() ?? 0,
      status: (json['status'] as String?) ?? '',
      statusColor: _hexToColor((json['statusColor'] as String?) ?? '22C55E'),
      icon: _iconFor((json['icon'] as String?) ?? 'folder'),
      iconColor: _hexToColor((json['iconColor'] as String?) ?? '2563EB'),
    );
  }
}

class MobileSessionData {
  final String name;
  final String dateTime;
  final int images;
  final int pending;
  final String tempMode;
  final String badge;
  final String duration;

  const MobileSessionData({
    required this.name,
    required this.dateTime,
    required this.images,
    required this.pending,
    required this.tempMode,
    required this.badge,
    required this.duration,
  });

  factory MobileSessionData.fromJson(Map<String, dynamic> json) {
    return MobileSessionData(
      name: (json['name'] as String?) ?? 'Session',
      dateTime: (json['dateTime'] as String?) ?? '',
      images: (json['images'] as num?)?.toInt() ?? 0,
      pending: (json['pending'] as num?)?.toInt() ?? 0,
      tempMode: (json['tempMode'] as String?) ?? 'None',
      badge: (json['badge'] as String?) ?? 'Local only',
      duration: (json['duration'] as String?) ?? '0m',
    );
  }
}

class UploadItem {
  final String fileName;
  final String capturedAt;
  final String status;
  final int retries;

  const UploadItem({
    required this.fileName,
    required this.capturedAt,
    required this.status,
    required this.retries,
  });

  factory UploadItem.fromJson(Map<String, dynamic> json) {
    return UploadItem(
      fileName: (json['fileName'] as String?) ?? 'file',
      capturedAt: (json['capturedAt'] as String?) ?? '--',
      status: (json['status'] as String?) ?? 'Pending',
      retries: (json['retries'] as num?)?.toInt() ?? 0,
    );
  }
}

class Stats {
  final int projects;
  final int sessions;
  final int images;
  final int temps;

  const Stats({
    required this.projects,
    required this.sessions,
    required this.images,
    required this.temps,
  });

  factory Stats.fromJson(Map<String, dynamic> json) {
    return Stats(
      projects: (json['projects'] as num?)?.toInt() ?? 0,
      sessions: (json['sessions'] as num?)?.toInt() ?? 0,
      images: (json['images'] as num?)?.toInt() ?? 0,
      temps: (json['temps'] as num?)?.toInt() ?? 0,
    );
  }

  Stats copyWith({int? projects, int? sessions, int? images, int? temps}) {
    return Stats(
      projects: projects ?? this.projects,
      sessions: sessions ?? this.sessions,
      images: images ?? this.images,
      temps: temps ?? this.temps,
    );
  }
}

Color _hexToColor(String hex) {
  final buffer = StringBuffer();
  if (hex.length == 6) buffer.write('ff');
  buffer.write(hex.toLowerCase().replaceAll('#', ''));
  return Color(int.parse(buffer.toString(), radix: 16));
}

IconData _iconFor(String key) {
  switch (key) {
    case 'camera':
      return Icons.camera_alt_outlined;
    case 'file':
      return Icons.insert_drive_file_outlined;
    default:
      return Icons.folder_open;
  }
}

Color _badgeColor(String badge) {
  switch (badge.toLowerCase()) {
    case 'uploaded':
      return const Color(0xFF22C55E);
    case 'partially uploaded':
      return const Color(0xFFF59E0B);
    case 'local only':
      return const Color(0xFF0EA5E9);
    case 'failed':
      return Colors.red;
    default:
      return const Color(0xFF6B7280);
  }
}

class PairingCard extends StatefulWidget {
  final ProjectData? activeProject;

  const PairingCard({super.key, required this.activeProject});

  @override
  State<PairingCard> createState() => _PairingCardState();
}

class _PairingCardState extends State<PairingCard> {
  final ScrollController _messageScrollController = ScrollController();

  @override
  void dispose() {
    _messageScrollController.dispose();
    super.dispose();
  }

  void _showFramePreview(
    BuildContext context,
    Uint8List bytes, {
    String? summary,
  }) {
    showDialog(
      context: context,
      builder: (ctx) {
        return Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(12),
                  ),
                  child: Container(
                    color: const Color(0xFF0B1220),
                    child: AspectRatio(
                      aspectRatio: 4 / 3,
                      child: InteractiveViewer(
                        child: Image.memory(
                          bytes,
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                        ),
                      ),
                    ),
                  ),
                ),
                if (summary != null) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Text(
                      summary,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text('Close'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openProjectWindow(
    BuildContext context,
    PairingServerState state,
  ) async {
    final scrollController = ScrollController();

    await showDialog(
      context: context,
      builder: (ctx) {
        return Dialog(
          insetPadding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100, maxHeight: 780),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.activeProject?.name ?? 'Project',
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 18,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              state.connected
                                  ? 'Live connection to handset ready'
                                  : 'Waiting for handset connection',
                              style: const TextStyle(color: Color(0xFF6B7280)),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          flex: 5,
                          child: Scrollbar(
                            controller: scrollController,
                            thumbVisibility: true,
                            child: SingleChildScrollView(
                              controller: scrollController,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      _MonitorStatusChip(
                                        icon: state.connected
                                            ? Icons.desktop_windows_outlined
                                            : Icons.desktop_access_disabled,
                                        label: state.connected
                                            ? 'Connected to desktop'
                                            : 'Not connected',
                                        color: state.connected
                                            ? const Color(0xFF16A34A)
                                            : const Color(0xFFF97316),
                                      ),
                                      _MonitorStatusChip(
                                        icon: state.temperatureLocked
                                            ? Icons.thermostat
                                            : Icons.thermostat_auto_outlined,
                                        label: state.temperatureLocked
                                            ? 'Temperature locked'
                                            : 'Awaiting temperature entry',
                                        color: state.temperatureLocked
                                            ? const Color(0xFF0EA5E9)
                                            : const Color(0xFFE11D48),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 14),
                                  Text(
                                    'Status: ${state.status}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  if (state.lastTemperature != null ||
                                      !state.temperatureLocked)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 8),
                                      child: Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Icon(
                                            state.temperatureLocked
                                                ? Icons.thermostat
                                                : Icons.hourglass_bottom,
                                            color: state.temperatureLocked
                                                ? Colors.orange
                                                : Colors.red,
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              state.temperatureLocked
                                                  ? 'Temperature locked at ${state.lastTemperature ?? '--'}'
                                                  : 'Awaiting temperature entry from phone before accepting images',
                                              style: const TextStyle(
                                                color: Color(0xFF4B5563),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  if (state.lastMessage != null)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 10),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          const Text(
                                            'Last message',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w700,
                                              color: Color(0xFF4B5563),
                                            ),
                                          ),
                                          const SizedBox(height: 6),
                                          Container(
                                            padding: const EdgeInsets.all(10),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFFF3F4F6),
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                              border: Border.all(
                                                color: const Color(0xFFE5E7EB),
                                              ),
                                            ),
                                            child: Text(
                                              state.lastMessage!,
                                              style: const TextStyle(
                                                color: Color(0xFF6B7280),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  if (state.lastFrameSummary != null)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 12),
                                      child: Text(
                                        'Last ROI frame: ${state.lastFrameSummary}',
                                        style: const TextStyle(
                                          color: Color(0xFF0F172A),
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          flex: 7,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(16),
                                  child: Container(
                                    decoration: const BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: [
                                          Color(0xFF0EA5E9),
                                          Color(0xFF1D4ED8),
                                        ],
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                      ),
                                    ),
                                    child: AspectRatio(
                                      aspectRatio: 4 / 3,
                                      child: state.lastFrameBytes != null
                                          ? InteractiveViewer(
                                              child: Image.memory(
                                                state.lastFrameBytes!,
                                                fit: BoxFit.contain,
                                                gaplessPlayback: true,
                                              ),
                                            )
                                          : const Center(
                                              child: Text(
                                                'No ROI frame received yet',
                                                style: TextStyle(
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                            ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  const Icon(
                                    Icons.open_in_full,
                                    color: Color(0xFF6B7280),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      state.lastFrameBytes != null
                                          ? 'Use pinch or mouse wheel to inspect the latest ROI image.'
                                          : 'Waiting for the first ROI image from the handset.',
                                      style: const TextStyle(
                                        color: Color(0xFF6B7280),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    scrollController.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PairingServerState>(
      valueListenable: PairingHost.instance.state,
      builder: (context, state, _) {
        if (widget.activeProject == null) {
          return _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text(
                  'Phone Connection',
                  style: TextStyle(
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  'Select a project to unlock pairing and QR codes.',
                  style: TextStyle(color: Color(0xFF6B7280)),
                ),
              ],
            ),
          );
        }

        final connected = state.connected;
        return _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Phone Connection • ${widget.activeProject!.name}',
                style: const TextStyle(
                  color: Color(0xFF6B7280),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _StatusDot(color: connected ? Colors.green : Colors.red),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      connected ? 'Connected' : 'Waiting for pairing',
                      style: TextStyle(
                        color: connected ? Colors.green : Colors.red,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (widget.activeProject != null)
                    TextButton.icon(
                      onPressed: () => _openProjectWindow(context, state),
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('Open project window'),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              if (state.qrData != null) ...[
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF9FAFB),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFE5E7EB)),
                    ),
                    child: QrImageView(
                      data: state.qrData!,
                      version: QrVersions.auto,
                      size: 160,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Scan with mobile to pair.\n${state.displayHost}',
                  style: const TextStyle(color: Color(0xFF6B7280)),
                ),
              ] else ...[
                const Text(
                  'Starting pairing service...',
                  style: TextStyle(color: Color(0xFF6B7280)),
                ),
              ],
              const SizedBox(height: 12),
              Text(
                'Status: ${state.status}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              if (state.lastTemperature != null ||
                  !state.temperatureLocked) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(
                      state.temperatureLocked
                          ? Icons.thermostat
                          : Icons.hourglass_bottom,
                      color: state.temperatureLocked
                          ? Colors.orange
                          : Colors.red,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        state.temperatureLocked
                            ? 'Temperature locked at ${state.lastTemperature ?? '--'}'
                            : 'Awaiting temperature entry from phone before accepting images',
                        style: const TextStyle(color: Color(0xFF4B5563)),
                      ),
                    ),
                  ],
                ),
              ],
              if (state.lastMessage != null) ...[
                const SizedBox(height: 6),
                const Text(
                  'Last message:',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF4B5563),
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  constraints: const BoxConstraints(maxHeight: 120),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF3F4F6),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFFE5E7EB)),
                  ),
                  child: Scrollbar(
                    controller: _messageScrollController,
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      controller: _messageScrollController,
                      child: Text(
                        state.lastMessage ?? '',
                        style: const TextStyle(color: Color(0xFF6B7280)),
                      ),
                    ),
                  ),
                ),
              ],
              if (state.lastFrameBytes != null) ...[
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: () => _showFramePreview(
                    context,
                    state.lastFrameBytes!,
                    summary: state.lastFrameSummary,
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      color: const Color(0xFF0B1220),
                      child: AspectRatio(
                        aspectRatio: 4 / 3,
                        child: Image.memory(
                          state.lastFrameBytes!,
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Tap preview to view full size on this screen.',
                  style: TextStyle(color: Color(0xFF6B7280), fontSize: 12),
                ),
              ],
              if (state.lastFrameSummary != null) ...[
                const SizedBox(height: 6),
                Text(
                  'Last ROI frame: ${state.lastFrameSummary}',
                  style: const TextStyle(
                    color: Color(0xFF0F172A),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              if (state.lastFrameBytes != null && state.temperatureLocked) ...[
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Evaluation pipeline will run here (OpenCV stub).',
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start Evaluating'),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size.fromHeight(44),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class PairingServerState {
  final bool running;
  final bool connected;
  final String status;
  final String? qrData;
  final String displayHost;
  final String? lastMessage;
  final String? lastFrameSummary;
  final Uint8List? lastFrameBytes;
  final String? lastTemperature;
  final bool temperatureLocked;

  const PairingServerState({
    required this.running,
    required this.connected,
    required this.status,
    required this.qrData,
    required this.displayHost,
    required this.lastMessage,
    required this.lastFrameSummary,
    required this.lastFrameBytes,
    required this.lastTemperature,
    required this.temperatureLocked,
  });

  PairingServerState copyWith({
    bool? running,
    bool? connected,
    String? status,
    String? qrData,
    String? displayHost,
    String? lastMessage,
    String? lastFrameSummary,
    Uint8List? lastFrameBytes,
    String? lastTemperature,
    bool? temperatureLocked,
  }) {
    return PairingServerState(
      running: running ?? this.running,
      connected: connected ?? this.connected,
      status: status ?? this.status,
      qrData: qrData ?? this.qrData,
      displayHost: displayHost ?? this.displayHost,
      lastMessage: lastMessage ?? this.lastMessage,
      lastFrameSummary: lastFrameSummary ?? this.lastFrameSummary,
      lastFrameBytes: lastFrameBytes ?? this.lastFrameBytes,
      lastTemperature: lastTemperature ?? this.lastTemperature,
      temperatureLocked: temperatureLocked ?? this.temperatureLocked,
    );
  }
}

class PairingHost {
  PairingHost._internal();
  static final PairingHost instance = PairingHost._internal();

  final ValueNotifier<PairingServerState> state =
      ValueNotifier<PairingServerState>(
        const PairingServerState(
          running: false,
          connected: false,
          status: 'Not started',
          qrData: null,
          displayHost: '',
          lastMessage: null,
          lastFrameSummary: null,
          lastFrameBytes: null,
          lastTemperature: null,
          temperatureLocked: false,
        ),
      );

  HttpServer? _server;
  WebSocket? _client;
  String _token = '';
  String? _host;
  int _port = 0;

  String _randomToken() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rand = Random.secure();
    return List.generate(12, (_) => chars[rand.nextInt(chars.length)]).join();
  }

  String _fmtNum(dynamic value) {
    if (value is num) {
      return value.toStringAsFixed(0);
    }
    return value?.toString() ?? '?';
  }

  void _forwardForAnalysis(Uint8List bytes) {
    // Placeholder for downstream analysis module integration.
    // Frames are made available through the state notifier and can be
    // consumed by future processing pipelines.
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (request.uri.path != '/pair') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    if (request.uri.queryParameters['token'] != _token) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      final socket = await WebSocketTransformer.upgrade(request);
      _client = socket;
      state.value = state.value.copyWith(
        connected: true,
        status:
            'Paired with ${request.connectionInfo?.remoteAddress.address ?? 'device'}',
      );
      socket.listen(
        (data) {
          final raw = data?.toString();
          try {
            final payload = jsonDecode(raw ?? '');
            if (payload is Map && payload['type'] == 'frame') {
              final roi = payload['roi'] as Map?;
              final pixels = roi?['pixels'] as Map?;
              Uint8List? frameBytes;
              final frameStr = payload['frame'];
              if (frameStr is String) {
                try {
                  frameBytes = base64Decode(frameStr);
                } catch (_) {}
              }
              final summary = pixels != null
                  ? 'ROI ${_fmtNum(pixels['width'])}x${_fmtNum(pixels['height'])} at (${_fmtNum(pixels['x'])}, ${_fmtNum(pixels['y'])})'
                  : 'ROI frame received';
              state.value = state.value.copyWith(
                lastMessage: raw,
                lastFrameSummary: summary,
                lastFrameBytes: frameBytes ?? state.value.lastFrameBytes,
              );
              if (frameBytes != null) {
                _forwardForAnalysis(frameBytes);
              }
              return;
            }
            if (payload is Map && payload['type'] == 'temperature') {
              final value = payload['value']?.toString();
              state.value = state.value.copyWith(
                lastMessage: raw,
                lastTemperature: value,
                temperatureLocked: true,
                status: 'Temperature locked at ${value ?? '--'}',
              );
              return;
            }
            if (payload is Map && payload['type'] == 'session_start') {
              state.value = state.value.copyWith(
                lastMessage: raw,
                status: 'Session ${payload['session'] ?? ''} ready',
              );
              return;
            }
          } catch (_) {}
          state.value = state.value.copyWith(lastMessage: raw);
        },
        onDone: () {
          state.value = state.value.copyWith(
            connected: false,
            status: 'Disconnected',
            lastFrameSummary: null,
          );
        },
      );
      socket.add(
        jsonEncode({
          'type': 'ack',
          'status': 'connected',
          'host': _host,
          'port': _port,
        }),
      );
    } else {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
    }
  }

  Future<void> stop() async {
    try {
      await _client?.close();
    } catch (_) {}
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _client = null;
    _server = null;
    state.value = const PairingServerState(
      running: false,
      connected: false,
      status: 'Not started',
      qrData: null,
      displayHost: '',
      lastMessage: null,
      lastFrameSummary: null,
      lastFrameBytes: null,
      lastTemperature: null,
      temperatureLocked: false,
    );
  }

  Future<void> startForProject(String projectName) async {
    await stop();
    if (state.value.running) return;
    if (kIsWeb) return;
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
        includeLoopback: false,
      );
      _host = interfaces
          .expand((i) => i.addresses)
          .firstWhere(
            (a) => !a.isLoopback && a.type == InternetAddressType.IPv4,
            orElse: () => InternetAddress.loopbackIPv4,
          )
          .address;
      _token = _randomToken();
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 8787);
      _port = _server!.port;
      _server!.listen(_handleRequest);
      final qr =
          'ws://$_host:$_port/pair?token=$_token&mode=live&project=${Uri.encodeComponent(projectName)}';
      state.value = state.value.copyWith(
        running: true,
        status: 'Awaiting scan for $projectName',
        qrData: qr,
        displayHost: 'ws://$_host:$_port',
        temperatureLocked: false,
        lastTemperature: null,
        lastFrameBytes: null,
        lastFrameSummary: null,
        lastMessage: null,
      );
    } catch (e) {
      state.value = state.value.copyWith(status: 'Failed to start pairing: $e');
    }
  }
}
