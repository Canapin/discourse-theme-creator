# frozen_string_literal: true

# name: discourse-theme-creator
# about: Allows users to create and share their own themes.
# version: 0.1
# author: David Taylor dtaylor.uk
# url: https://www.github.com/discourse/discourse-theme-creator
# transpile_js: true

register_asset "stylesheets/theme-creator.scss"
register_svg_icon "arrow-left"
register_svg_icon "arrow-right"
register_svg_icon "laptop-code"
register_svg_icon "eye"

load File.expand_path("../lib/theme_creator/engine.rb", __FILE__)

after_initialize do
  require_relative "app/jobs/scheduled/cleanup_topics"

  # We're re-using a lot of locale strings from the admin section
  # so we need to load it for non-staff users.
  register_html_builder("server:before-head-close") do |ctx|
    ctx.helpers.preload_script_url(ExtraLocalesController.url("admin")) +
      ctx.helpers.preload_script("admin") + ctx.helpers.discourse_stylesheet_link_tag(:admin)
  end

  # Override guardian to allow users to preview their own themes using the ?preview_theme_id= variable
  add_to_class(:guardian, :allow_themes?) do |theme_ids, include_preview: false|
    theme_ids = [theme_ids] unless theme_ids.is_a?(Array)
    return true if theme_ids.all? { |id| Theme.user_theme_ids.include?(id) } # Is a 'user selectable theme'
    return false if theme_ids.any? { |id| not Theme.theme_ids.include?(id) } # Is not a valid theme

    # If you own the theme, you are allowed to view it using GET param
    # Even staff are not allowed to use GET to access other user's themes, to reduce XSS attack risk
    theme_ids.all? { |id| can_hotlink_user_theme?(Theme.find_by(id: id)) }
  end

  add_to_class(:guardian, :allowed_theme_repo_import?) do |repo|
    # Skip checking the allowed_theme_repos allowlist
    true
  end

  add_to_class(:guardian, :can_hotlink_user_theme?) { |theme| is_my_own?(theme) }

  add_to_class(:guardian, :can_see_user_theme?) do |theme|
    return true if is_staff?

    return true if is_my_own?(theme)

    # Theme is shared and theme owner has permission to share
    theme.is_shared && User.find_by(id: theme.user_id)&.guardian&.can_share_user_theme?(theme)
  end

  add_to_class(:guardian, :can_edit_user_theme?) { |theme| is_staff? || is_my_own?(theme) }

  add_to_class(:guardian, :can_share_user_theme?) do |theme|
    return true if SiteSetting.theme_creator_share_groups.blank? # all users can share

    # Check if user is in any allowed groups
    allowed_groups = SiteSetting.theme_creator_share_groups.split("|")
    @user.groups.where(name: allowed_groups).exists?
  end

  # Add methods so that a theme can be shared/unshared by the user
  add_to_class(:theme, :is_shared) { !!share_slug }

  add_to_class(:theme, :share_slug) do
    @share_slug ||= PluginStore.get("discourse-theme-creator", "share:#{user_id}:#{id}")
  end

  add_to_class(:theme, :share_destination) do
    @share_destination ||=
      PluginStore.get("discourse-theme-creator", "share_destination:#{user_id}:#{id}")
  end

  add_model_callback(:theme, :after_destroy) do
    PluginStore.remove("discourse-theme-creator", "share:#{user_id}:#{id}")
  end

  add_to_class(:theme, :share_slug=) do |val|
    if !val
      @share_slug = nil
      PluginStore.remove("discourse-theme-creator", "share:#{user_id}:#{id}")
      return
    end

    val = val.downcase
    valid = (/^[a-z0-9_-]+$/ =~ val)
    return false if !valid

    unique =
      !PluginStoreRow
        .where(plugin_name: "discourse-theme-creator")
        .where("key LIKE ?", "share:#{user_id}:%")
        .where(value: val)
        .any?
    return false if !unique

    @share_slug = val
    PluginStore.set("discourse-theme-creator", "share:#{user_id}:#{id}", val)
  end

  add_to_class(:theme, :share_destination=) do |val|
    if !val
      @share_slug = nil
      PluginStore.remove("discourse-theme-creator", "share_destination:#{user_id}:#{id}")
      return
    end

    @share_destination = val
    PluginStore.set("discourse-theme-creator", "share_destination:#{user_id}:#{id}", val)
  end

  # We block hotlinking of other users themes.
  # If an admin wants to see another users theme, redirect them to the share UI.
  add_to_class(::Admin::ThemesController, :preview) do
    @theme ||= Theme.find(params[:id])

    can_hotlink = guardian.can_hotlink_user_theme?(@theme)
    can_view = guardian.can_see_user_theme?(@theme)

    if !can_hotlink && can_view
      redirect_to path("/theme/#{@theme.id}")
    else
      raise Discourse::InvalidAccess.new() if !can_hotlink
      redirect_to path("/?preview_theme_id=#{@theme.id}")
    end
  end

  add_to_serializer(:theme, :is_shared) { object.is_shared }

  add_to_serializer(:theme, :share_slug) { object.share_slug }

  add_to_serializer(:theme, :share_destination) { object.share_destination }

  add_to_serializer(:theme, :base_share_url) do
    UrlHelper.absolute_without_cdn("/theme/#{object.user&.username}/")
  end

  add_to_serializer(:theme, :base_destination_url) { Discourse.base_url_no_prefix }

  add_to_serializer(:theme, :can_share) do
    User.find_by(id: object.user_id)&.guardian&.can_share_user_theme?(object)
  end

  # Allow preview of shared user themes
  # flash[:user_theme_id] will only be populated after a POST request
  # after a UI confirmation (theme_creator_controller.rb) to prevent hotlinking
  reloadable_patch do |plugin|
    class ::ApplicationController
      module ThemeCreatorOverrides
        def handle_theme
          super()
          user_theme_id = flash[:user_theme_id]
          if user_theme_id && Theme.theme_ids.include?(user_theme_id) && # Has requested a valid theme
               guardian.can_see_user_theme?(Theme.find_by(id: user_theme_id))
            @theme_id = request.env[:resolved_theme_id] = user_theme_id
          end
        end
      end
      prepend ThemeCreatorOverrides
    end
  end

  reloadable_patch do |plugin|
    class ::ExtraLocalesController
      module ThemeCreatorOverrides
        def show
          bundle = params[:bundle]

          if params[:v]&.size == 32
            hash = ExtraLocalesController.bundle_js_hash(bundle)
            immutable_for(24.hours) if hash == params[:v]
          end

          render plain: ExtraLocalesController.bundle_js(bundle),
                 content_type: "application/javascript"
        end
      end
      prepend ThemeCreatorOverrides
    end
  end

  add_user_api_key_scope(
    :user_themes,
    [
      { methods: :post, actions: "theme_creator/theme_creator#import" },
      { methods: :put, actions: "theme_creator/theme_creator#update" },
      { methods: :get, actions: "theme_creator/theme_creator#list" },
      { methods: :get, actions: "theme_creator/theme_creator#export" },
      { methods: :get, actions: "about#index" },
    ],
  )
end
