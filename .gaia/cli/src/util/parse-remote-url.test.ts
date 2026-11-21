import {describe, expect, test} from 'vitest';
import {parseRemoteUrl} from './parse-remote-url.js';

const OWNER_REPO = {owner: 'owner', repo: 'repo'};

describe('parseRemoteUrl', () => {
  test.each(
    [
      {
        host: 'github.com',
        name: 'parses scp-style SSH with .git',
        url: 'git@github.com:owner/repo.git',
      },
      {
        host: 'github.com',
        name: 'parses scp-style SSH without .git',
        url: 'git@github.com:owner/repo',
      },
      {
        host: 'github.com',
        name: 'parses HTTPS with .git',
        url: 'https://github.com/owner/repo.git',
      },
      {
        host: 'github.com',
        name: 'parses HTTPS without .git',
        url: 'https://github.com/owner/repo',
      },
      {
        host: 'github.com',
        name: 'parses ssh:// protocol with .git',
        url: 'ssh://git@github.com/owner/repo.git',
      },
      {
        host: 'gitlab.com',
        name: 'preserves non-github host (caller branches on host)',
        url: 'https://gitlab.com/owner/repo.git',
      },
      {
        host: 'bitbucket.org',
        name: 'preserves non-github host on scp-style',
        url: 'git@bitbucket.org:owner/repo.git',
      },
    ].map((row) => [row.name, row] as const)
  )('%s', (_name, {host, url}) => {
    expect(parseRemoteUrl(url)).toEqual({...OWNER_REPO, host, url});
  });

  test.each(
    [
      {name: 'returns null for empty string', url: ''},
      {name: 'returns null for whitespace', url: ' '.repeat(3)},
      {name: 'returns null for malformed URL', url: 'not a url'},
      {
        name: 'returns null for HTTPS with subgroups (3 path segments)',
        url: 'https://gitlab.com/foo/bar/baz.git',
      },
      {
        name: 'returns null for SSH with subgroups',
        url: 'git@gitlab.com:group/subgroup/repo.git',
      },
      {name: 'returns null for missing repo', url: 'https://github.com/owner'},
      {
        name: 'returns null for trailing-slash-only URL',
        url: 'https://github.com/',
      },
      {
        name: 'returns null for ssh:// missing path',
        url: 'ssh://git@github.com/',
      },
    ].map((row) => [row.name, row] as const)
  )('%s', (_name, {url}) => {
    expect(parseRemoteUrl(url)).toBeNull();
  });
});
