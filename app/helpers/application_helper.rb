module ApplicationHelper
  def id_of_pawprint_form_for(item)
    "pawprint-form-for-item-#{item.id}"
  end

  def id_of_subscription_button_for(channel)
    "subscription-button-for-channel-#{channel.id}"
  end

  def user_avatar_tag(user, size: :small, css_class: nil)
    size_config = {
      xs: { dimension: "24x24", css: "w-6 h-6", variant: :small },
      small: { dimension: "36x36", css: "w-9 h-9", variant: :small },
      thumb: { dimension: "128x128", css: "w-32 h-32", variant: :thumb },
      display: { dimension: "512x512", css: "w-128 h-128", variant: :display }
    }

    config = size_config[size] || size_config[:small]
    css_classes = [ config[:css], "rounded-full object-cover", css_class ].compact.join(" ")

    image_tag user.avatar_url(variant: config[:variant]), size: config[:dimension], class: css_classes
  end
end
