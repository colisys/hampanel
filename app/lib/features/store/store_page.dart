import 'package:material_ui/material_ui.dart';

import '../../ui/theme.dart';
import 'docker_apps_tab.dart';
import 'nix_tab.dart';
import 'packages_tab.dart';

class StorePage extends StatelessWidget {
  const StorePage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(24, 20, 24, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 5,
                            height: 20,
                            color: hampanelAccent,
                          ),
                          const SizedBox(width: 10),
                          const Text(
                            '应用商店',
                            style: TextStyle(
                              fontSize: 21,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Docker Compose 应用 · 系统工具 · Nix 运行与构建',
                        style: TextStyle(fontSize: 12.5, color: hampanelMuted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [
                  Tab(text: 'Docker 应用'),
                  Tab(text: '系统工具'),
                  Tab(text: 'Nix'),
                ],
              ),
            ),
          ),
          const Expanded(
            child: TabBarView(
              children: [DockerAppsTab(), PackagesTab(), NixTab()],
            ),
          ),
        ],
      ),
    );
  }
}
