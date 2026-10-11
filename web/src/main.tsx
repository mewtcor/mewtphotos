import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { Dashboard } from './Dashboard.tsx';
import { Phone } from './Phone.tsx';
import './styles.css';

// Two pages, one bundle: the laptop opens /dashboard, the iPhone opens /.
const Page = location.pathname.startsWith('/dashboard') ? Dashboard : Phone;

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <Page />
  </StrictMode>,
);
