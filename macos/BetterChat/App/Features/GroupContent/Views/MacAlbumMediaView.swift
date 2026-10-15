import QQBridgeProto
import SwiftUI

struct MacAlbumMediaView: View {
  @State private var model: MacAlbumMediaViewModel
  @State private var gallery: URLGallery?
  let title: String

  init(service: any MacAlbumMediaService, title: String) {
    _model = State(initialValue: MacAlbumMediaViewModel(service: service))
    self.title = title
  }

  var body: some View {
    ScrollView {
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2, pinnedViews: [.sectionHeaders]) {
        ForEach(model.sections) { section in
          Section {
            ForEach(section.items) { entry in
              thumbnail(entry)
                .onAppear { model.reached(entry.id) }
            }
          } header: {
            sectionHeader(section)
          }
        }
      }
      if !model.media.isEmpty { pagination }
    }
    .overlay { emptyState }
    .navigationTitle(title.isEmpty ? model.name : title)
    .navigationBarTitleDisplayMode(.inline)
    .urlGallery($gallery)
    .onAppear { model.start() }
    .onDisappear { model.cancel() }
  }

  private func thumbnail(_ entry: MacAlbumMediaViewModel.Entry) -> some View {
    Button {
      gallery = URLGallery(items: model.media.map(AlbumMediaView.galleryItem), index: entry.index)
    } label: {
      Color.clear.aspectRatio(1, contentMode: .fit)
        .overlay { RemoteImage(url: URL(string: entry.media.thumbURL), maxPixel: 400) }
        .clipped()
        .overlay(alignment: .bottomLeading) {
          if entry.media.isVideo { Image(systemName: "play.fill").font(.caption).foregroundStyle(.white).shadow(radius: 2).padding(6) }
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(entry.media.isVideo ? "视频" : "图片") \(entry.index + 1)")
    .accessibilityValue([Format.date(entry.media.time), entry.media.uploaderName].filter { !$0.isEmpty }.joined(separator: " · "))
    .help(entry.media.isVideo ? "打开视频" : "查看大图")
  }

  private func sectionHeader(_ section: MacAlbumMediaViewModel.Section) -> some View {
    let names = Array(Set(section.items.map(\.media.uploaderName).filter { !$0.isEmpty })).sorted()
    return HStack {
      Text(section.day).font(.footnote.weight(.semibold))
      Spacer()
      if !names.isEmpty { Text(names.prefix(3).joined(separator: "、")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
    }
    .padding(.horizontal, 12).padding(.vertical, 6)
    .background(.bar)
  }

  @ViewBuilder private var pagination: some View {
    VStack(spacing: 8) {
      if model.isLoading { ProgressView("正在加载更多照片…") }
      else if let error = model.error {
        Text(error).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        Button("重试加载") { model.loadMore() }
      } else if model.hasMore {
        Button("加载更多") { model.loadMore() }
      }
    }
    .padding()
    .frame(maxWidth: .infinity)
  }

  @ViewBuilder private var emptyState: some View {
    if model.media.isEmpty {
      if model.isLoading || (!model.hasLoaded && model.error == nil) { ProgressView() }
      else if let error = model.error {
        ContentUnavailableView {
          Label("照片加载失败", systemImage: "exclamationmark.triangle")
        } description: {
          Text(error)
        } actions: {
          Button("重试加载") { model.loadMore() }
        }
      } else if model.hasMore {
        ContentUnavailableView {
          Label("当前页没有照片", systemImage: "photo")
        } description: {
          Text("可以继续加载相册中的其他照片。")
        } actions: {
          Button("加载更多") { model.loadMore() }
        }
      } else {
        ContentUnavailableView("相册是空的", systemImage: "photo")
      }
    }
  }
}
