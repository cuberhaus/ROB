import EmberRouter from '@embroider/router';
import config from 'web/config/environment';

export default class Router extends EmberRouter {
  location = config.locationType;
  rootURL = config.rootURL;
}

Router.map(function () {
  this.route('mobile');
  this.route('wall-following');
  this.route('arm');
  this.route('trajectory');
  this.route('sensors');
  this.route('ekf');
});
