import SwiftUI

struct HostListView: View {
    @State private var hosts: [SSHHost] = SSHHost.loadAll()
    @State private var showingAddHost = false
    @State private var selectedHost: SSHHost?

    var body: some View {
        NavigationStack {
            List {
                ForEach(hosts) { host in
                    Button {
                        selectedHost = host
                    } label: {
                        VStack(alignment: .leading) {
                            Text(host.label).font(.headline)
                            Text("\(host.username)@\(host.hostname):\(host.port)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { indexSet in
                    hosts.remove(atOffsets: indexSet)
                    SSHHost.saveAll(hosts)
                }
            }
            .navigationTitle("Warp")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingAddHost = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showingAddHost) {
                AddHostView { newHost in
                    hosts.append(newHost)
                    SSHHost.saveAll(hosts)
                }
            }
            .fullScreenCover(item: $selectedHost) { host in
                ConnectedTerminalView(host: host)
            }
        }
    }
}
