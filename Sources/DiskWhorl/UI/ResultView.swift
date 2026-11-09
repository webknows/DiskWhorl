import SwiftUI

struct ResultView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: ScanSession

    var body: some View {
        VStack(spacing: 0) {
            ResultHeader(session: session)
            Divider()
            HStack(spacing: 0) {
                SunburstMap(session: session, actions: actions)
                    .frame(minWidth: 460, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
                    .padding(8)
                Divider()
                InspectorView(session: session)
                    .frame(width: 340)
            }
            Divider()
            CollectorBar(session: session, collector: session.collector)
        }
        .sheet(isPresented: $session.showHiddenSpaceTools) {
            HiddenSpaceView(session: session)
                .environmentObject(model)
        }
    }

    private var actions: SunburstActions {
        let model = self.model
        let session = self.session
        return SunburstActions(
            quickLook: { model.quickLook($0) },
            reveal: { model.reveal($0) },
            collect: { session.collector.add($0) },
            copyPath: { model.copyPath($0) }
        )
    }
}

private struct ResultHeader: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: ScanSession

    var body: some View {
        HStack(spacing: 10) {
            Button {
                session.goUp()
            } label: {
                Image(systemName: "chevron.backward")
            }
            .disabled(session.center?.parent == nil)
            .help("Up one level (⌘↑)")

            BreadcrumbBar(session: session)

            Spacer(minLength: 8)

            if session.adminMode {
                Label("Administrator", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)

            if session.isVolumeScan {
                Button {
                    session.showHiddenSpaceTools = true
                } label: {
                    Label("Hidden Space", systemImage: "eye.slash")
                }
                .help("Snapshots, purgeable and system space (⇧⌘H)")
            }
            Button {
                model.rescan(session)
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .help("Scan again; results do not update on their own")
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var summary: String {
        let files = session.root?.fileCount ?? 0
        return "\(files.formatted()) files · scanned in \(ByteFormat.duration(session.duration))"
    }
}

private struct BreadcrumbBar: View {
    @ObservedObject var session: ScanSession

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    let chain = session.center?.lineage ?? []
                    ForEach(chain.indices, id: \.self) { index in
                        let node = chain[index]
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        Button {
                            session.navigate(to: node)
                        } label: {
                            HStack(spacing: 4) {
                                if index == 0 {
                                    Image(systemName: session.isVolumeScan ? "internaldrive" : "folder")
                                }
                                Text(node.title)
                                    .fontWeight(index == chain.count - 1 ? .semibold : .regular)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(index == chain.count - 1 ? Color.accentColor.opacity(0.14) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        .id(node.id)
                        .help(node.path)
                    }
                }
            }
            .onChange(of: session.center?.id) { _, newValue in
                if let newValue {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(newValue, anchor: .trailing) }
                }
            }
        }
    }
}
