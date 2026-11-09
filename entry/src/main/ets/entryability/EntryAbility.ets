import { AbilityConstant, common, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const DOMAIN: number = 0x0000;
const TAG: string = 'HarmonyScale';
/** AppStorage key：UIAbility 上下文，供页面初始化 preferences 使用 */
const KEY_ABILITY_CONTEXT: string = 'app_ability_context';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'onCreate');
    // getContext(this) 已废弃。Ability 创建时把上下文存入 AppStorage，
    // 页面 aboutToAppear 从中取用，避免依赖 UIContext 挂载时机。
    AppStorage.setOrCreate<common.UIAbilityContext>(KEY_ABILITY_CONTEXT, this.context);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'loadContent success');
    });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onDestroy');
  }
}
