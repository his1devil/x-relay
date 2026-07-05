import SwiftUI

struct DiffView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let payload: DiffPayload

    var body: some View {
        VStack(spacing: 0) {
            header
            rows
            footer
        }
        .background(theme.screen.ignoresSafeArea())
        .navigationBarHidden(true)
    }

    private var header: some View {
        HStack(spacing: 11) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(theme.sub)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(payload.fileName)
                    .font(AppFont.mono(14, .semibold))
                    .foregroundStyle(theme.white)
                if let dir = payload.dir {
                    Text(dir)
                        .font(AppFont.mono(10.5))
                        .foregroundStyle(theme.faint)
                }
            }
            Spacer(minLength: 4)
            Text("+\(payload.addCount)").font(AppFont.mono(12)).foregroundStyle(theme.addText)
            Text("−\(payload.delCount)").font(AppFont.mono(12)).foregroundStyle(theme.delText)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
    }

    private var rows: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(payload.rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 0) {
                        Text(row.oldNo.map(String.init) ?? "")
                            .frame(width: 30, alignment: .trailing)
                            .foregroundStyle(theme.faint)
                        Text(row.newNo.map(String.init) ?? "")
                            .frame(width: 30, alignment: .trailing)
                            .foregroundStyle(theme.faint)
                            .padding(.trailing, 8)
                        Text(row.sign.isEmpty ? " " : row.sign)
                            .frame(width: 14, alignment: .center)
                            .foregroundStyle(signColor(row.sign))
                        Text(row.text.isEmpty ? " " : row.text)
                            .foregroundStyle(codeColor(row.sign))
                            .padding(.trailing, 18)
                    }
                    .font(AppFont.mono(12))
                    .lineSpacing(4)
                    .padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(rowBg(row.sign))
                }
            }
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(theme.greenText).frame(width: 6, height: 6)
                Text("applied")
                    .font(AppFont.mono(11))
                    .foregroundStyle(theme.muted)
            }
            Spacer()
            Button { dismiss() } label: {
                Text("Done")
                    .font(AppFont.sans(13.5, .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 9)
                    .background(theme.blurple, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
    }

    private func signColor(_ sign: String) -> Color {
        sign == "+" ? theme.addText : sign == "-" ? theme.delText : theme.faint
    }

    private func codeColor(_ sign: String) -> Color {
        sign == "+" ? theme.addText : sign == "-" ? theme.delText : theme.sub
    }

    private func rowBg(_ sign: String) -> Color {
        sign == "+" ? theme.addBg : sign == "-" ? theme.delBg : Color.clear
    }
}
