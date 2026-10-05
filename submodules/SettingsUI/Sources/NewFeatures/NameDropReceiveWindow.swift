import Foundation
import UIKit

public final class NameDropOverlay {
    public static let shared = NameDropOverlay()

    private var window: UIWindow?
    private var cardView: UIView?
    private var currentPayload: NameDropPayload?
    public var onAddChat: ((NameDropPayload) -> Void)?

    private init() {}

    public func show(payload: NameDropPayload) {
        assert(Thread.isMainThread)
        self.currentPayload = payload
        self.hide(animated: false)

        guard let scene = self.activeScene() else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        window.backgroundColor = .clear

        let root = UIViewController()
        root.view.backgroundColor = .clear
        window.rootViewController = root

        let card = self.makeCard(payload: payload)
        root.view.addSubview(card)
        card.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: root.view.safeAreaLayoutGuide.topAnchor, constant: 12),
            card.leadingAnchor.constraint(equalTo: root.view.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: root.view.trailingAnchor, constant: -12),
        ])

        // Slide from top, like an AirDrop / notification banner.
        card.transform = CGAffineTransform(translationX: 0, y: -24)
        card.alpha = 0
        window.isHidden = false
        self.window = window
        self.cardView = card

        UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0.6, options: [.curveEaseOut], animations: {
            card.transform = .identity
            card.alpha = 1.0
        })

        // Auto-dismiss after 25 seconds if ignored.
        DispatchQueue.main.asyncAfter(deadline: .now() + 25.0) { [weak self] in
            guard let self, self.currentPayload?.peerId == payload.peerId, self.currentPayload?.fullName == payload.fullName else { return }
            self.hide(animated: true)
        }
    }

    public func hide(animated: Bool = true) {
        assert(Thread.isMainThread)
        guard let window = self.window, let card = self.cardView else {
            self.window = nil
            self.cardView = nil
            self.currentPayload = nil
            return
        }
        self.currentPayload = nil
        if !animated {
            window.isHidden = true
            self.window = nil
            self.cardView = nil
            return
        }
        UIView.animate(withDuration: 0.22, animations: {
            card.transform = CGAffineTransform(translationX: 0, y: -16)
            card.alpha = 0
        }, completion: { [weak self] _ in
            window.isHidden = true
            self?.window = nil
            self?.cardView = nil
        })
    }

    // MARK: - Card

    private func makeCard(payload: NameDropPayload) -> UIView {
        let card = UIView()
        card.layer.cornerRadius = 20
        card.layer.masksToBounds = true
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.22
        card.layer.shadowRadius = 18
        card.layer.shadowOffset = CGSize(width: 0, height: 8)

        let baseColor: UIColor
        if let hex = payload.backgroundColorHex {
            baseColor = UIColor.namedrop_color(hex: hex)
        } else {
            if #available(iOS 13.0, *) {
                baseColor = .secondarySystemBackground
            } else {
                baseColor = .white
            }
        }
        card.backgroundColor = baseColor

        // Background emoji watermark (Premium customization, independent from profile).
        if let emoji = payload.backgroundEmoji, !emoji.isEmpty {
            let watermark = UILabel()
            watermark.text = emoji
            watermark.font = UIFont.systemFont(ofSize: 120)
            watermark.textAlignment = .center
            watermark.alpha = 0.16
            watermark.isUserInteractionEnabled = false
            watermark.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(watermark)
            NSLayoutConstraint.activate([
                watermark.centerXAnchor.constraint(equalTo: card.centerXAnchor),
                watermark.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            ])
        }

        let titleLabel = UILabel()
        titleLabel.text = "NameDrop"
        titleLabel.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = baseColor.isLight ? UIColor(white: 0.25, alpha: 1.0) : UIColor(white: 1.0, alpha: 0.75)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(titleLabel)

        let avatarView = self.makeAvatar(payload: payload, baseColor: baseColor)
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(avatarView)

        let nameLabel = UILabel()
        nameLabel.text = payload.fullName
        nameLabel.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        nameLabel.textColor = baseColor.isLight ? .black : .white
        nameLabel.numberOfLines = 1
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(nameLabel)

        let usernameLabel = UILabel()
        if let username = payload.username, !username.isEmpty {
            usernameLabel.text = "@\(username)"
            usernameLabel.isHidden = false
        } else {
            usernameLabel.text = nil
            usernameLabel.isHidden = true
        }
        usernameLabel.font = UIFont.systemFont(ofSize: 14, weight: .regular)
        usernameLabel.textColor = baseColor.isLight ? UIColor(white: 0.35, alpha: 1.0) : UIColor(white: 1.0, alpha: 0.8)
        usernameLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(usernameLabel)

        let ignoreButton = UIButton(type: .system)
        ignoreButton.setTitle(self.localizedIgnore(), for: .normal)
        ignoreButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .regular)
        ignoreButton.backgroundColor = baseColor.isLight ? UIColor(white: 0.0, alpha: 0.06) : UIColor(white: 1.0, alpha: 0.16)
        ignoreButton.setTitleColor(baseColor.isLight ? .black : .white, for: .normal)
        ignoreButton.layer.cornerRadius = 12
        ignoreButton.translatesAutoresizingMaskIntoConstraints = false
        ignoreButton.addTarget(self, action: #selector(self.ignoreTapped), for: .touchUpInside)
        card.addSubview(ignoreButton)

        let addButton = UIButton(type: .system)
        addButton.setTitle(self.localizedAddChat(), for: .normal)
        addButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        addButton.backgroundColor = UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)
        addButton.setTitleColor(.white, for: .normal)
        addButton.layer.cornerRadius = 12
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.addTarget(self, action: #selector(self.addChatTapped), for: .touchUpInside)
        card.addSubview(addButton)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            titleLabel.centerXAnchor.constraint(equalTo: card.centerXAnchor),

            avatarView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            avatarView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            avatarView.widthAnchor.constraint(equalToConstant: 60),
            avatarView.heightAnchor.constraint(equalToConstant: 60),

            nameLabel.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            nameLabel.topAnchor.constraint(equalTo: avatarView.topAnchor, constant: 6),

            usernameLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            usernameLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            usernameLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),

            ignoreButton.topAnchor.constraint(equalTo: avatarView.bottomAnchor, constant: 14),
            ignoreButton.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            ignoreButton.heightAnchor.constraint(equalToConstant: 44),

            addButton.topAnchor.constraint(equalTo: ignoreButton.topAnchor),
            addButton.leadingAnchor.constraint(equalTo: ignoreButton.trailingAnchor, constant: 10),
            addButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            addButton.heightAnchor.constraint(equalTo: ignoreButton.heightAnchor),
            addButton.widthAnchor.constraint(equalTo: ignoreButton.widthAnchor),

            ignoreButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ])

        return card
    }

    private func makeAvatar(payload: NameDropPayload, baseColor: UIColor) -> UIView {
        let size: CGFloat = 60
        let container = UIView()
        container.layer.cornerRadius = size / 2
        container.layer.masksToBounds = true

        if let b64 = payload.avatarDataBase64, let data = Data(base64Encoded: b64), let image = UIImage(data: data) {
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleAspectFill
            imageView.frame = CGRect(x: 0, y: 0, width: size, height: size)
            imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(imageView)
            container.backgroundColor = .clear
        } else {
            container.backgroundColor = UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)
            let label = UILabel()
            label.text = String(payload.fullName.prefix(1)).uppercased()
            label.font = UIFont.systemFont(ofSize: 26, weight: .semibold)
            label.textColor = .white
            label.textAlignment = .center
            label.frame = CGRect(x: 0, y: 0, width: size, height: size)
            label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(label)
        }
        return container
    }

    private func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes
        for scene in scenes {
            if let windowScene = scene as? UIWindowScene, scene.activationState == .foregroundActive {
                return windowScene
            }
        }
        for scene in scenes {
            if let windowScene = scene as? UIWindowScene {
                return windowScene
            }
        }
        return nil
    }

    private func localizedIgnore() -> String {
        if let s = Bundle.main.localizedString(forKey: "NewFeatures.Receive.Ignore", value: nil, table: nil), s != "NewFeatures.Receive.Ignore" {
            return s
        }
        return "Ignore"
    }

    private func localizedAddChat() -> String {
        if let s = Bundle.main.localizedString(forKey: "NewFeatures.Receive.AddChat", value: nil, table: nil), s != "NewFeatures.Receive.AddChat" {
            return s
        }
        return "Add Chat"
    }

    @objc private func ignoreTapped() {
        self.hide(animated: true)
    }

    @objc private func addChatTapped() {
        guard let payload = self.currentPayload else { return }
        let handler = self.onAddChat
        self.hide(animated: true)
        // Open the chat after the banner dismisses.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            handler?(payload)
        }
    }
}

private extension UIColor {
    var isLight: Bool {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        if self.getRed(&r, green: &g, blue: &b, alpha: &a) {
            // Relative luminance approximation.
            let lum = 0.299 * r + 0.587 * g + 0.114 * b
            return lum > 0.6
        }
        var w: CGFloat = 0
        if self.getWhite(&w, alpha: &a) {
            return w > 0.6
        }
        return true
    }
}
