// Main app — orchestrates theme, hero variant switching, and lays out page sections.

const { useState: useAppState, useEffect: useAppEffect } = React;

function TopBar({ theme, setTheme }) {
  const C = theme === 'dark'
    ? { fg: '#e5e5e5', dim: '#8a8a92', border: '#1e1e22', chip: '#101012', chipActive: '#26262a', chipBorder: '#26262a' }
    : { fg: '#0a0a0a', dim: '#4a4a48', border: '#e4e4e2', chip: '#ffffff', chipActive: '#e8e8e6', chipBorder: '#d8d8d6' };
  return (
    <header style={{
      position: 'sticky', top: 0, zIndex: 50,
      background: theme === 'dark' ? 'rgba(10,10,11,0.9)' : 'rgba(250,250,249,0.94)',
      borderBottom: `1px solid ${C.border}`,
    }}>
      <div className="wg-container" style={{
        display: 'flex', alignItems: 'center', height: 60, gap: 16,
      }}>
        <WinghosttyWordmark size={24} theme={theme} />
        <div style={{ flex: 1 }} />
        <WinghosttyToggle theme={theme} onToggle={() => setTheme(theme === 'dark' ? 'light' : 'dark')} />
        <a href="https://github.com/amanthanvi/winghostty" target="_blank" rel="noreferrer"
          style={{
            height: 36, padding: '0 14px', borderRadius: 9, background: C.chip,
            border: `1px solid ${C.chipBorder}`, color: C.fg, textDecoration: 'none',
            fontFamily: 'var(--mono)', fontSize: 12, display: 'inline-flex', alignItems: 'center', gap: 8,
          }}
        >
          <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor">
            <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0016 8c0-4.42-3.58-8-8-8z"/>
          </svg>
          GitHub
        </a>
      </div>
    </header>
  );
}

function App() {
  const [theme, setTheme] = useAppState(() => localStorage.getItem('wg-theme') || 'dark');

  useAppEffect(() => { localStorage.setItem('wg-theme', theme); }, [theme]);

  // apply theme tokens to body
  useAppEffect(() => {
    document.body.dataset.theme = theme;
    document.body.style.background = theme === 'dark' ? '#0a0a0b' : '#fafaf9';
    document.body.style.color = theme === 'dark' ? '#e5e5e5' : '#0a0a0a';
  }, [theme]);

  // Edit-mode (tweaks) wiring — listen first, then announce.
  useAppEffect(() => {
    const onMessage = (e) => {
      const d = e.data || {};
      if (d.type === '__activate_edit_mode') document.body.dataset.editMode = 'on';
      if (d.type === '__deactivate_edit_mode') document.body.dataset.editMode = 'off';
    };
    window.addEventListener('message', onMessage);
    window.parent?.postMessage({ type: '__edit_mode_available' }, '*');
    return () => window.removeEventListener('message', onMessage);
  }, []);

  const C = theme === 'dark'
    ? { fg: '#e5e5e5', dim: '#8a8a92', rule: '#1e1e22', label: '#707078' }
    : { fg: '#0a0a0a', dim: '#4a4a48', rule: '#d8d8d6', label: '#6a6a68' };

  const Hero = HeroColorPop;

  const SectionLabel = ({ num, title }) => (
    <div style={{
      display: 'flex', alignItems: 'baseline', gap: 12, marginBottom: 24,
    }}>
      <span style={{
        fontFamily: 'var(--mono)', fontSize: 11, color: C.label,
        letterSpacing: '0.14em', textTransform: 'uppercase',
      }}>{num}</span>
      <span style={{
        fontSize: 22, fontWeight: 500, color: C.fg, letterSpacing: '-0.02em',
      }}>{title}</span>
    </div>
  );

  return (
    <>
      <TopBar theme={theme} setTheme={setTheme} />
      <main>
        <div className="wg-container" style={{ paddingTop: 40, paddingBottom: 56 }}>
          <Hero theme={theme} />
        </div>

        <div className="wg-container" style={{ paddingTop: 40, paddingBottom: 56, contentVisibility: 'auto', containIntrinsicSize: '760px' }}>
          <SectionLabel num="01" title="What you get" />
          <FeatureGrid theme={theme} />
        </div>

        <div className="wg-container" style={{ paddingTop: 32, paddingBottom: 48, contentVisibility: 'auto', containIntrinsicSize: '540px' }}>
          <SectionLabel num="02" title="Why a fork?" />
          <WhyFork theme={theme} />
        </div>

        <div className="wg-container" style={{ contentVisibility: 'auto', containIntrinsicSize: '220px' }}>
          <Footer theme={theme} />
        </div>
      </main>
    </>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<App />);
