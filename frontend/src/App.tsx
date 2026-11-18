import { useEffect, useState } from "react";
import Spinner from "@cloudscape-design/components/spinner";
import Box from "@cloudscape-design/components/box";
import { completeLogin, login, logout, userEmail } from "./auth";
import AppLayout from "@cloudscape-design/components/app-layout";
import SideNavigation from "@cloudscape-design/components/side-navigation";
import AskPage from "./AskPage";
import DocumentTreeArchitecturePage from "./DocumentTreeArchitecturePage";

const PAGES: Record<string, () => JSX.Element> = {
  "#ask": AskPage,
  "#architecture": DocumentTreeArchitecturePage,
};

export default function App() {
  const [active, setActive] = useState("#ask");
  const [navOpen, setNavOpen] = useState(true);
  const [signedIn, setSignedIn] = useState(false);
  const [authError, setAuthError] = useState("");
  const Page = PAGES[active] ?? AskPage;

  useEffect(() => {
    completeLogin()
      .then((ok) => (ok ? setSignedIn(true) : login()))
      .catch((error) => setAuthError(error instanceof Error ? error.message : "Sign-in failed."));
  }, []);

  if (authError) {
    return (
      <Box color="text-status-error" textAlign="center" padding="xxxl">
        {authError}
      </Box>
    );
  }

  if (!signedIn) {
    return (
      <Box textAlign="center" padding="xxxl">
        <Spinner size="large" /> <Box variant="p">Signing in...</Box>
      </Box>
    );
  }

  return (
    <AppLayout
      toolsHide
      navigationOpen={navOpen}
      onNavigationChange={(e) => setNavOpen(e.detail.open)}
      navigation={
        <SideNavigation
          activeHref={active}
          header={{ href: "#ask", text: "Smart Factory Search" }}
          onFollow={(e) => {
            e.preventDefault();
            if (e.detail.href === "#signout") return logout();
            setActive(e.detail.href);
          }}
          items={[
            {
              type: "section",
              text: "Document Tree v3",
              items: [
                { type: "link", text: "Ask a Manual", href: "#ask" },
                { type: "link", text: "Architecture", href: "#architecture" },
              ],
            },
            { type: "divider" },
            { type: "link", text: `Sign out (${userEmail()})`, href: "#signout" },
          ]}
        />
      }
      content={<Page />}
    />
  );
}
