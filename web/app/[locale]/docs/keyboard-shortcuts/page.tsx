import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../../i18n/seo";
import { Link } from "../../../../i18n/navigation";
import { Callout } from "../../components/callout";
import { CodeBlock } from "../../components/code-block";
import { KeyboardShortcuts } from "../../keyboard-shortcuts";
import { DocsHeading } from "../../components/docs-heading";

const shortcutChordExample = `{
  "shortcuts": {
    "bindings": {
      "newSurface": ["ctrl+b", "c"],
      "showNotifications": ["ctrl+b", "i"],
      "toggleSidebar": "cmd+b",
      "toggleFileExplorer": "cmd+opt+b",
      "splitRight": "",
      "commandPalettePrevious": null
    }
  }
}`;

const tilingShortcutExample = `{
  "shortcuts": {
    "bindings": {
      "tilingTile": ["ctrl+b", "t"],
      "tilingMonocle": ["ctrl+b", "m"],
      "tilingFocusNext": ["ctrl+b", "j"],
      "tilingFocusPrevious": ["ctrl+b", "k"],
      "tilingPromote": ["ctrl+b", "return"],
      "tilingManual": ["ctrl+b", "f"]
    }
  }
}`;

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.keyboardShortcuts" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/docs/keyboard-shortcuts"),
  };
}

export default function KeyboardShortcutsPage() {
  const t = useTranslations("docs.keyboardShortcuts");

  return (
    <>
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("description")}</p>

      <DocsHeading level={2} id="shortcut-chords" className="scroll-mt-24">{t("chordsTitle")}</DocsHeading>
      <p>
        {t.rich("chordsIntro", {
          settingsFile: (chunks) => <code>{chunks}</code>,
          configurationLink: (chunks) => <Link href="/docs/configuration">{chunks}</Link>,
        })}
      </p>
      <Callout type="info">{t("chordsCallout")}</Callout>
      <CodeBlock title="cmux.json" lang="json">{shortcutChordExample}</CodeBlock>
      <ul>
        <li>{t("chordsRuleSingle")}</li>
        <li>{t("chordsRuleArray")}</li>
        <li>{t("chordsRuleSyntax")}</li>
      </ul>

      <DocsHeading level={2} id="pane-tiling" className="scroll-mt-24">{t("tilingTitle")}</DocsHeading>
      <p>{t("tilingIntro")}</p>
      <p>{t("tilingActions")}</p>
      <CodeBlock title="cmux.json" lang="json">{tilingShortcutExample}</CodeBlock>
      <p>{t("tilingAutomation")}</p>
      <CodeBlock lang="bash">{`cmux rpc workspace.tiling.action '{"action":"tile"}'
cmux rpc workspace.tiling.state '{}'`}</CodeBlock>
      <p>{t("tilingActionNames")}</p>
      <CodeBlock lang="text">{`tile, monocle, toggleLayout, focusNext, focusPrevious,
moveNext, movePrevious, promote, increaseMasterCount,
decreaseMasterCount, increaseMasterRatio, decreaseMasterRatio, manual`}</CodeBlock>

      <KeyboardShortcuts />
    </>
  );
}
