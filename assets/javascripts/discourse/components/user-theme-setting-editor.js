import ThemeSettingEditor from "admin/components/theme-setting-editor";
import { url } from "discourse/lib/computed";

export default class UserThemeSettingEditor extends ThemeSettingEditor {
  updateUrl = url("model.id", "/user_themes/%@/setting");
}
