import SwiftUI

struct ContentView: View {
    @State private var role: Role? = nil

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                NavigationLink(destination: HostViewContainer(), tag: .host, selection: $role) {
                    EmptyView()
                }
                NavigationLink(destination: ViewerViewContainer(), tag: .viewer, selection: $role) {
                    EmptyView()
                }

                Text("multipla-poc")
                    .font(.largeTitle)
                    .padding()

                Button("Host (stream)") { role = .host }
                Button("Viewer (receive)") { role = .viewer }
                Spacer()
            }
            .padding()
            .navigationTitle("Choose role")
        }
    }

    enum Role {
        case host, viewer
    }
}

struct HostViewContainer: View {
    var body: some View {
        HostViewControllerWrapper()
            .edgesIgnoringSafeArea(.all)
    }
}

struct ViewerViewContainer: View {
    var body: some View {
        ViewerViewControllerWrapper()
            .edgesIgnoringSafeArea(.all)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
